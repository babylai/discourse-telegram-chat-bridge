# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Converts Discourse's cooked chat message HTML into Telegram's small
  # HTML parse_mode subset, prefixed with the author's name (Telegram bots
  # can't post a message as an arbitrary user, so the name is inlined).
  class TelegramFormatter
    MAX_MESSAGE_LENGTH = 4096

    SIMPLE_TAGS = {
      "strong" => "b",
      "b" => "b",
      "em" => "i",
      "i" => "i",
      "u" => "u",
      "ins" => "u",
      "s" => "s",
      "strike" => "s",
      "del" => "s",
      "code" => "code",
      "pre" => "pre",
      "blockquote" => "blockquote",
    }.freeze

    def self.format(cooked, prefix:)
      new(cooked, prefix: prefix).format
    end

    # The bare `<b>name:</b>` author prefix, e.g. for media captions.
    def self.prefix_html(prefix)
      "<b>#{CGI.escapeHTML(prefix.to_s)}:</b>"
    end

    def initialize(cooked, prefix:)
      @cooked = cooked.to_s
      @prefix = prefix
    end

    def format
      body = render(fragment).strip
      full = "<b>#{escape(@prefix)}:</b> #{body}".strip

      return [full] if full.length <= MAX_MESSAGE_LENGTH

      # A long, formatted message risks a split landing mid-tag and
      # breaking Telegram's HTML parser entirely - degrade to plain text.
      plain = "#{@prefix}: #{plain_text}"
      plain.scan(/.{1,#{MAX_MESSAGE_LENGTH}}/m)
    end

    private

    def fragment
      Nokogiri::HTML5.fragment(@cooked)
    end

    def render(node)
      node.children.map { |child| render_child(child) }.join
    end

    def render_child(node)
      return escape(node.text) if node.text?
      return "" if !node.element?

      inner = render(node)

      case node.name
      when "br"
        "\n"
      when "p", "div", "li"
        "#{inner}\n"
      when "img"
        # Discourse cooks emojis into <img class="emoji"> tags - without
        # this they'd render as nothing on the Telegram side.
        node["class"].to_s.split.include?("emoji") ? escape(emoji_unicode(node)) : ""
      when "a"
        href = node["href"]
        href.present? ? %(<a href="#{escape(href)}">#{inner}</a>) : inner
      when *SIMPLE_TAGS.keys
        tag = SIMPLE_TAGS[node.name]
        "<#{tag}>#{inner}</#{tag}>"
      else
        inner
      end
    end

    def escape(text)
      CGI.escapeHTML(text.to_s)
    end

    # ":joy:" -> 😂, ":+1:t2:" -> 👍🏻; custom emojis have no unicode and
    # fall back to their ":shortcode:" text.
    def emoji_unicode(node)
      name = node["title"].to_s.sub(/\A:/, "").sub(/:\z/, "")
      ::Emoji.lookup_unicode(name).presence || node["title"].to_s
    end

    # Plain-text rendering for the long-message fallback, with emoji imgs
    # substituted first so they survive .text extraction.
    def plain_text
      doc = fragment
      doc.css("img.emoji").each do |img|
        img.replace(Nokogiri::XML::Text.new(emoji_unicode(img), img.document))
      end
      doc.text.strip
    end
  end
end
