# frozen_string_literal: true

describe DiscourseTelegramChatBridge::TelegramFormatter do
  def format(cooked)
    described_class.format(cooked, prefix: "maria")
  end

  it "prefixes the message with the bolded username" do
    expect(format("<p>hello world</p>")).to eq(["<b>maria:</b> hello world"])
  end

  it "joins multiple paragraphs with a newline" do
    expect(format("<p>first</p><p>second</p>")).to eq(["<b>maria:</b> first\nsecond"])
  end

  it "maps formatting tags to Telegram's HTML subset" do
    expect(format("<p><strong>bold</strong> <em>italic</em> <code>code</code></p>")).to eq(
      ["<b>maria:</b> <b>bold</b> <i>italic</i> <code>code</code>"],
    )
  end

  it "keeps link hrefs" do
    expect(format('<p><a href="https://example.com">link</a></p>')).to eq(
      ['<b>maria:</b> <a href="https://example.com">link</a>'],
    )
  end

  it "drops unsupported tags but keeps their text content" do
    expect(format('<div class="onebox"><p>some excerpt</p></div>')).to eq(
      ["<b>maria:</b> some excerpt"],
    )
  end

  it "escapes stray HTML-significant characters in text" do
    expect(format("<p>a &lt; b &amp; c &gt; d</p>")).to eq(["<b>maria:</b> a &lt; b &amp; c &gt; d"])
  end

  it "escapes HTML-significant characters in the prefix" do
    expect(described_class.format("<p>hi</p>", prefix: "<script>")).to eq(
      ["<b>&lt;script&gt;:</b> hi"],
    )
  end

  it "converts cooked emoji imgs to their unicode character" do
    cooked =
      '<p>ha <img src="/images/emoji/twitter/joy.png?v=12" title=":joy:" class="emoji" alt=":joy:"></p>'

    expect(format(cooked)).to eq(["<b>maria:</b> ha 😂"])
  end

  it "handles an emoji-only message (the only-emoji case)" do
    cooked =
      '<p><img src="/images/emoji/twitter/joy.png?v=12" title=":joy:" class="emoji only-emoji" alt=":joy:"></p>'

    expect(format(cooked)).to eq(["<b>maria:</b> 😂"])
  end

  it "converts skin-tone emoji variants" do
    cooked =
      '<p><img src="/images/emoji/twitter/+1/2.png?v=12" title=":+1:t2:" class="emoji" alt=":+1:t2:"></p>'

    expect(format(cooked)).to eq(["<b>maria:</b> #{Emoji.lookup_unicode("+1:t2")}"])
  end

  it "falls back to the shortcode for custom emojis without a unicode equivalent" do
    cooked =
      '<p><img src="/uploads/default/original/1X/blob.png" title=":blobwave:" class="emoji emoji-custom" alt=":blobwave:"></p>'

    expect(format(cooked)).to eq(["<b>maria:</b> :blobwave:"])
  end

  it "still drops non-emoji images" do
    expect(format('<p>look <img src="/uploads/x.png" alt="a picture"></p>')).to eq(
      ["<b>maria:</b> look"],
    )
  end

  it "keeps emojis in the plain-text long-message fallback" do
    long_word = "a" * 5000
    cooked =
      "<p>#{long_word} <img src=\"/images/emoji/twitter/joy.png?v=12\" title=\":joy:\" class=\"emoji\" alt=\":joy:\"></p>"

    expect(format(cooked).join).to include("😂")
  end

  it "degrades to plain-text chunks instead of risking malformed HTML when too long" do
    long_word = "a" * 5000
    result = format("<p><strong>#{long_word}</strong></p>")

    expect(result.size).to eq(2)
    expect(result.join).not_to include("<strong>", "<b>")
    expect(result.join).to include("maria: #{long_word}")
  end
end
