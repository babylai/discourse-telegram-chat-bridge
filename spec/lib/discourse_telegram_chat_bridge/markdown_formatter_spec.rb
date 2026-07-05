# frozen_string_literal: true

describe DiscourseTelegramChatBridge::MarkdownFormatter do
  def format(text, entities = [])
    described_class.format(text, entities)
  end

  it "returns plain text unchanged when there are no entities" do
    expect(format("hello world")).to eq("hello world")
  end

  it "wraps a bold entity in double asterisks" do
    expect(format("hello world", [{ "type" => "bold", "offset" => 6, "length" => 5 }])).to eq(
      "hello **world**",
    )
  end

  it "wraps an italic entity in single asterisks" do
    expect(format("hello world", [{ "type" => "italic", "offset" => 0, "length" => 5 }])).to eq(
      "*hello* world",
    )
  end

  it "wraps a strikethrough entity" do
    expect(
      format("hello world", [{ "type" => "strikethrough", "offset" => 0, "length" => 11 }]),
    ).to eq("~~hello world~~")
  end

  it "wraps a code entity in backticks" do
    expect(format("run cmd now", [{ "type" => "code", "offset" => 4, "length" => 3 }])).to eq(
      "run `cmd` now",
    )
  end

  it "wraps a pre entity in a fenced code block" do
    expect(format("puts 1", [{ "type" => "pre", "offset" => 0, "length" => 6 }])).to eq(
      "```\nputs 1\n```",
    )
  end

  it "converts a text_link entity into a markdown link" do
    result =
      format(
        "click here",
        [{ "type" => "text_link", "offset" => 0, "length" => 10, "url" => "https://example.com" }],
      )
    expect(result).to eq("[click here](https://example.com)")
  end

  it "handles multiple sequential entities" do
    result =
      format(
        "bold and italic",
        [
          { "type" => "bold", "offset" => 0, "length" => 4 },
          { "type" => "italic", "offset" => 9, "length" => 6 },
        ],
      )
    expect(result).to eq("**bold** and *italic*")
  end

  it "leaves unsupported entity types (e.g. mentions) as plain text" do
    expect(
      format("hi @someone", [{ "type" => "mention", "offset" => 3, "length" => 8 }]),
    ).to eq("hi @someone")
  end

  it "correctly offsets entities after an emoji (UTF-16 surrogate pair)" do
    # "🎉" is one Ruby character but two UTF-16 code units - the offset
    # below is in Telegram's UTF-16 units, and should still land on "world".
    text = "🎉 world"
    expect(format(text, [{ "type" => "bold", "offset" => 3, "length" => 5 }])).to eq("🎉 **world**")
  end
end
