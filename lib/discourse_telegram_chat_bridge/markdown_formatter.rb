# frozen_string_literal: true

module DiscourseTelegramChatBridge
  # Converts a Telegram message's plain text + entities (bold/italic/...)
  # into Discourse markdown. Entity offsets/lengths are defined by the Bot
  # API in UTF-16 code units, not Ruby character indices, so a naive
  # char-index approach silently misaligns as soon as the text contains any
  # emoji or other character outside the BMP - this maps through UTF-16
  # code units explicitly to stay correct.
  #
  # Unsupported entity types (mentions, spoilers, underline, ...) are left
  # as plain text rather than guessing at a Discourse equivalent.
  class MarkdownFormatter
    MARKERS = {
      "bold" => %w[** **],
      "italic" => %w[* *],
      "strikethrough" => %w[~~ ~~],
      "code" => %w[` `],
    }.freeze

    def self.format(text, entities)
      new(text, entities).format
    end

    def initialize(text, entities)
      @text = text.to_s
      # Outer (longer) entities first, so nested markers accumulate in the
      # correct order at shared start/end positions.
      @entities = (entities || []).sort_by { |e| [e["offset"], -e["length"]] }
    end

    def format
      return @text if @entities.empty?

      char_for_unit = utf16_char_boundaries
      inserts = Hash.new(+"")

      @entities.each do |entity|
        start_pos = char_for_unit[entity["offset"]] || @text.length
        last_unit = entity["offset"] + entity["length"] - 1
        end_pos = char_for_unit[last_unit] ? char_for_unit[last_unit] + 1 : @text.length

        before, after = markers_for(entity)
        next if before.nil?

        inserts[start_pos] += before
        inserts[end_pos] = after + inserts[end_pos]
      end

      result = +""
      (0..@text.length).each do |pos|
        result << inserts[pos] if inserts.key?(pos)
        result << @text[pos] if pos < @text.length
      end
      result
    end

    private

    def markers_for(entity)
      case entity["type"]
      when *MARKERS.keys
        MARKERS[entity["type"]]
      when "pre"
        ["```\n", "\n```"]
      when "text_link"
        ["[", "](#{entity["url"]})"]
      end
    end

    def utf16_char_boundaries
      map = []
      @text.each_char.with_index do |char, char_index|
        units = char.encode("UTF-16LE").bytesize / 2
        units.times { map << char_index }
      end
      map
    end
  end
end
