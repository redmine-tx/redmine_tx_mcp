require File.expand_path('test_helper', __dir__)
require 'ostruct'

class IssueToolTest < ActiveSupport::TestCase
  FakeNamedRecord = Struct.new(:id, :name, :firstname, :lastname, :login, :mail, :identifier, keyword_init: true)
  FakeIssue = Struct.new(
    :subject, :description, :status_id, :priority_id,
    :assigned_to_id, :category_id, :fixed_version_id, :parent_issue_id,
    :start_date, :due_date, :estimated_hours, :done_ratio, :notes
  )
  FakeStatus = Struct.new(:id, :name, :closed, :stage_value, :stage_label, keyword_init: true) do
    def is_closed?
      closed
    end

    def stage
      stage_value
    end

    def stage_name
      stage_label
    end

    def is_paused?
      false
    end
  end
  FakeRelation = Struct.new(:id, :type_for_issue, :other_issue_record, :delay, keyword_init: true) do
    def relation_type_for(_issue)
      type_for_issue
    end

    def other_issue(_issue)
      other_issue_record
    end
  end

  test "assign_issue_update_attributes allows clearing nullable fields" do
    issue = FakeIssue.new(
      'subject', 'desc', 1, 2,
      3, 4, 5, 6,
      Date.new(2026, 3, 1), Date.new(2026, 3, 2), 8.0, 50, nil
    )

    RedmineTxMcp::Tools::IssueTool.send(
      :assign_issue_update_attributes,
      issue,
      {
        'description' => nil,
        'assigned_to_id' => nil,
        'category_id' => '',
        'fixed_version_id' => nil,
        'parent_issue_id' => '',
        'start_date' => nil,
        'due_date' => '',
        'estimated_hours' => nil
      }
    )

    assert_nil issue.description
    assert_nil issue.assigned_to_id
    assert_nil issue.category_id
    assert_nil issue.fixed_version_id
    assert_nil issue.parent_issue_id
    assert_nil issue.start_date
    assert_nil issue.due_date
    assert_nil issue.estimated_hours
  end

  test "issue_update_fields_present accepts null clears as updates" do
    result = RedmineTxMcp::Tools::IssueTool.send(
      :issue_update_fields_present?,
      { 'assigned_to_id' => nil }
    )

    assert_equal true, result
  end

  test "parse_filter_date supports normalized absolute and relative dates" do
    today = Date.current

    assert_equal Date.new(2026, 3, 14), RedmineTxMcp::Tools::IssueTool.send(:parse_filter_date, '2026/03/14', 'updated_since')
    assert_equal today - 1, RedmineTxMcp::Tools::IssueTool.send(:parse_filter_date, '어제', 'updated_since')
    assert_equal today + 3, RedmineTxMcp::Tools::IssueTool.send(:parse_filter_date, '3일 후', 'updated_since')
  end

  test "parse_filter_date raises a clear error for invalid values" do
    error = assert_raises(ArgumentError) do
      RedmineTxMcp::Tools::IssueTool.send(:parse_filter_date, 'banana', 'updated_since')
    end

    assert_match(/updated_since must be YYYY-MM-DD/, error.message)
  end

  test "resolve_name_filter_ids matches compact full names and identifiers" do
    records = [
      FakeNamedRecord.new(id: 1, firstname: '길동', lastname: '홍', login: 'honggildong'),
      FakeNamedRecord.new(id: 2, name: 'QA Ready', identifier: 'qa-ready')
    ]

    assert_equal [1], RedmineTxMcp::Tools::IssueTool.send(:resolve_name_filter_ids, records, '홍길동')
    assert_equal [2], RedmineTxMcp::Tools::IssueTool.send(:resolve_name_filter_ids, records, 'qa ready')
  end

  test "normalize_relation_type accepts standard aliases" do
    assert_equal 'blocked', RedmineTxMcp::Tools::IssueTool.send(:normalize_relation_type, 'blocked_by', 'relation_type')
    assert_equal 'relates', RedmineTxMcp::Tools::IssueTool.send(:normalize_relation_type, 'related', 'relation_type')
  end

  test "format_issue_list_item stays lightweight while format_issue_details includes parent and relations" do
    issue = build_detailed_issue

    summary = RedmineTxMcp::Tools::IssueTool.send(:format_issue_list_item, issue)
    detail = RedmineTxMcp::Tools::IssueTool.send(:format_issue_details, issue, chatbot: true)

    assert_equal 'summary', summary[:detail_level]
    assert_equal 77, summary[:parent_issue_id]
    assert_equal 1, summary[:relation_count]
    assert_equal true, summary.dig(:relation_summary, :has_predecessor)
    assert_equal false, summary.dig(:relation_summary, :has_successor)
    assert_equal false, summary.key?(:description)

    assert_equal 'detail', detail[:detail_level]
    assert_equal 'Investigate login dependency', detail[:description]
    assert_equal 77, detail.dig(:parent_issue, :id)
    assert_equal 'follows', detail.dig(:relations, 0, :relation_type)
    assert_equal 456, detail.dig(:relations, 0, :other_issue, :id)
  end

  private

  def build_detailed_issue
    tracker = OpenStruct.new(id: 1, name: 'Task')
    status = FakeStatus.new(id: 2, name: 'In Progress', closed: false, stage_value: 2, stage_label: 'In Progress')
    priority = OpenStruct.new(id: 3, name: 'High')
    assignee = OpenStruct.new(id: 4, name: '홍길동')
    author = OpenStruct.new(id: 5, name: '작성자')
    category = OpenStruct.new(id: 6, name: 'Backend')
    version = OpenStruct.new(id: 7, name: 'Sprint 1')
    project = OpenStruct.new(id: 8, name: 'Demo', identifier: 'demo')
    parent = OpenStruct.new(id: 77, subject: 'Authentication epic')
    other_issue = OpenStruct.new(
      id: 456,
      subject: 'Finalize SSO contract',
      tracker: tracker,
      status: status,
      assigned_to: assignee,
      start_date: Date.new(2026, 3, 10),
      due_date: Date.new(2026, 3, 20),
      done_ratio: 20
    )
    def other_issue.visible?(_user=nil)
      true
    end

    relation = FakeRelation.new(id: 9, type_for_issue: 'follows', other_issue_record: other_issue, delay: 1)

    OpenStruct.new(
      id: 123,
      subject: 'Implement login flow',
      description: 'Investigate login dependency',
      project: project,
      tracker: tracker,
      status: status,
      priority: priority,
      author: author,
      assigned_to: assignee,
      category: category,
      fixed_version: version,
      parent: parent,
      parent_id: parent.id,
      relations: [relation],
      start_date: Date.new(2026, 3, 14),
      due_date: Date.new(2026, 3, 21),
      estimated_hours: 8.0,
      spent_hours: 3.5,
      done_ratio: 40,
      worker: nil,
      guide_tag: nil,
      tip: nil,
      created_on: Time.utc(2026, 3, 14, 9, 0, 0),
      updated_on: Time.utc(2026, 3, 14, 10, 0, 0),
      closed_on: nil
    )
  end
end
