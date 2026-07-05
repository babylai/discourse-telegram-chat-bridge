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
      plain = "#{@prefix}: #{fragment.text.strip}"
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
  end
end
