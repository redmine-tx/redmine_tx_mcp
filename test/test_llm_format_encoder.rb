require File.expand_path('test_helper', __dir__)

class LlmFormatEncoderTest < ActiveSupport::TestCase
  test "paginated encoding preserves notice metadata" do
    text = RedmineTxMcp::LlmFormatEncoder.encode(
      {
        items: [{ id: 1, subject: 'Alpha' }],
        pagination: { page: 1, per_page: 10, total_count: 23, total_pages: 3 },
        returned_count: 1,
        has_more: true,
        next_page: 2,
        notice: 'Showing page 1 only.'
      }
    )

    assert_match(/page: 1 \| per_page: 10 \| total: 23 \| pages: 3/, text)
    assert_match(/notice: Showing page 1 only\./, text)
    assert_match(/has_more: true/, text)
    assert_match(/next_page: 2/, text)
  end
end
