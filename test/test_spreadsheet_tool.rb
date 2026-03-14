require File.expand_path('test_helper', __dir__)
require 'tmpdir'
require 'tempfile'

class SpreadsheetToolTest < ActiveSupport::TestCase
  test "spreadsheet document can write and read a simple xlsx workbook" do
    workbook = RedmineTxMcp::SpreadsheetDocument.build_xlsx(
      sheet_name: 'Report',
      columns: %w[issue_id status],
      rows: [
        { 'issue_id' => 101, 'status' => 'QA' },
        { 'issue_id' => 102, 'status' => 'Done' }
      ],
      summary_lines: ['bulk update completed']
    )

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'report.xlsx')
      File.binwrite(path, workbook)
      document = RedmineTxMcp::SpreadsheetDocument.new(path)

      sheets = document.list_sheets
      assert_equal ['Summary', 'Report'], sheets.map { |sheet| sheet[:name] }

      extracted = document.extract_rows(sheet_name: 'Report')
      assert_equal %w[issue_id status], extracted[:columns]
      assert_equal 2, extracted[:rows].size
      assert_equal 101, extracted[:rows].first['issue_id']
    end
  end

  test "spreadsheet export report creates a downloadable xlsx file in the chatbot workspace" do
    session_id = "spreadsheet-tool-#{SecureRandom.hex(4)}"
    workspace = RedmineTxMcp::ChatbotWorkspace.new(user_id: 1, project_id: 1, session_id: session_id)

    result = RedmineTxMcp::Tools::SpreadsheetTool.call_tool(
      'spreadsheet_export_report',
      {
        '_chatbot_workspace' => { 'user_id' => 1, 'project_id' => 1, 'session_id' => session_id },
        'file_name' => 'issue-summary',
        'columns' => %w[issue_id status],
        'rows' => [
          { 'issue_id' => 201, 'status' => 'QA' }
        ],
        'summary_lines' => ['1 issue updated']
      }
    )

    assert_equal 'issue-summary.xlsx', result[:file_name]
    assert_match(%r{/projects/1/chatbot/reports/issue-summary\.xlsx}, result[:download_path])
    assert File.exist?(workspace.resolve_report(result[:file_name])[:path])
  ensure
    workspace&.clear!
  end

  test "spreadsheet export normalizes invalid and duplicate sheet names" do
    workbook = RedmineTxMcp::SpreadsheetDocument.build_xlsx(
      sheet_name: 'Summary/Blocked*Items',
      columns: ['issue_id'],
      rows: [{ 'issue_id' => 201 }],
      summary_lines: ['done']
    )

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'normalized.xlsx')
      File.binwrite(path, workbook)

      sheets = RedmineTxMcp::SpreadsheetDocument.new(path).list_sheets
      assert_equal ['Summary', 'Summary_Blocked_Items'], sheets.map { |sheet| sheet[:name] }
    end
  end

  test "spreadsheet list uploads returns saved session files" do
    session_id = "spreadsheet-uploads-#{SecureRandom.hex(4)}"
    workspace = RedmineTxMcp::ChatbotWorkspace.new(user_id: 1, project_id: 1, session_id: session_id)
    workbook = RedmineTxMcp::SpreadsheetDocument.build_xlsx(
      sheet_name: 'Sheet1',
      columns: ['name'],
      rows: [{ 'name' => 'demo' }]
    )
    workspace.save_upload(
      ActionDispatch::Http::UploadedFile.new(
        tempfile: Tempfile.new(['demo', '.xlsx']).tap { |file| file.binmode; file.write(workbook); file.rewind },
        filename: 'demo.xlsx',
        type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      )
    )

    result = RedmineTxMcp::Tools::SpreadsheetTool.call_tool(
      'spreadsheet_list_uploads',
      { '_chatbot_workspace' => { 'user_id' => 1, 'project_id' => 1, 'session_id' => session_id } }
    )

    assert_equal 1, result[:count]
    assert_equal 'demo.xlsx', result[:files].first[:stored_name]
  ensure
    workspace&.clear!
  end
end
