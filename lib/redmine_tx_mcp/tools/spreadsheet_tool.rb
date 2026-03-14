module RedmineTxMcp
  module Tools
    class SpreadsheetTool < BaseTool
      class << self
        def available_tools
          [
            {
              name: 'spreadsheet_list_uploads',
              description: 'List spreadsheet files uploaded in the current chatbot session. Use this first when the user refers to an uploaded Excel, CSV, or TSV file.',
              inputSchema: {
                type: 'object',
                properties: {}
              }
            },
            {
              name: 'spreadsheet_list_sheets',
              description: 'List the sheets of an uploaded spreadsheet file and show lightweight dimensions. If only one spreadsheet is uploaded, file_name may be omitted.',
              inputSchema: {
                type: 'object',
                properties: {
                  file_name: { type: 'string', description: 'Uploaded file name, such as report.xlsx' }
                }
              }
            },
            {
              name: 'spreadsheet_preview_sheet',
              description: 'Preview a small window of rows from one sheet. Use this to inspect the layout before extracting structured rows.',
              inputSchema: {
                type: 'object',
                properties: {
                  file_name: { type: 'string', description: 'Uploaded file name, such as report.xlsx' },
                  sheet_name: { type: 'string', description: 'Sheet name. Omit to use the first sheet.' },
                  sheet_index: { type: 'integer', description: '1-based sheet index. Use when the sheet name is not known.' },
                  start_row: { type: 'integer', description: '1-based row number to start from', default: 1 },
                  max_rows: { type: 'integer', description: 'Number of rows to preview (max 50)', default: 20 },
                  max_columns: { type: 'integer', description: 'Number of columns to preview (max 20)', default: 12 }
                }
              }
            },
            {
              name: 'spreadsheet_extract_rows',
              description: 'Extract structured rows from one sheet using a header row. Use this for actual reasoning or follow-up issue updates based on spreadsheet data.',
              inputSchema: {
                type: 'object',
                properties: {
                  file_name: { type: 'string', description: 'Uploaded file name, such as report.xlsx' },
                  sheet_name: { type: 'string', description: 'Sheet name. Omit to use the first sheet.' },
                  sheet_index: { type: 'integer', description: '1-based sheet index. Use when the sheet name is not known.' },
                  header_row: { type: 'integer', description: '1-based row containing column headers', default: 1 },
                  row_offset: { type: 'integer', description: 'How many data rows to skip after the header row', default: 0 },
                  row_limit: { type: 'integer', description: 'How many data rows to return (max 300)', default: 100 },
                  columns: {
                    type: 'array',
                    items: { type: 'string' },
                    description: 'Optional subset of normalized header names to return'
                  }
                }
              }
            },
            {
              name: 'spreadsheet_export_report',
              description: 'Create a downloadable xlsx report in the current chatbot session. Use this when the user wants the final result as an Excel file.',
              inputSchema: {
                type: 'object',
                properties: {
                  file_name: { type: 'string', description: 'Desired output filename. .xlsx is added automatically if missing.' },
                  sheet_name: { type: 'string', description: 'Worksheet name for the exported data', default: 'Report' },
                  summary_lines: {
                    type: 'array',
                    items: { type: 'string' },
                    description: 'Optional summary lines for a Summary sheet'
                  },
                  columns: {
                    type: 'array',
                    items: { type: 'string' },
                    description: 'Column order for the exported data sheet'
                  },
                  rows: {
                    type: 'array',
                    items: { type: 'object' },
                    description: 'Rows to export as objects keyed by the provided columns'
                  }
                },
                required: %w[file_name columns rows]
              }
            }
          ]
        end

        def call_tool(tool_name, arguments)
          case tool_name
          when 'spreadsheet_list_uploads'
            list_uploads(arguments)
          when 'spreadsheet_list_sheets'
            list_sheets(arguments)
          when 'spreadsheet_preview_sheet'
            preview_sheet(arguments)
          when 'spreadsheet_extract_rows'
            extract_rows(arguments)
          when 'spreadsheet_export_report'
            export_report(arguments)
          else
            { error: "Unknown tool: #{tool_name}" }
          end
        rescue => e
          handle_error(e)
        end

        private

        def list_uploads(arguments)
          workspace = workspace_from(arguments)
          {
            files: workspace.list_uploads,
            count: workspace.list_uploads.count
          }
        end

        def list_sheets(arguments)
          workspace = workspace_from(arguments)
          file = workspace.resolve_upload(arguments['file_name'])
          document = SpreadsheetDocument.new(file[:path])
          {
            file_name: file[:stored_name],
            sheets: document.list_sheets
          }
        end

        def preview_sheet(arguments)
          workspace = workspace_from(arguments)
          file = workspace.resolve_upload(arguments['file_name'])
          document = SpreadsheetDocument.new(file[:path])
          document.preview_sheet(
            sheet_name: arguments['sheet_name'],
            sheet_index: arguments['sheet_index'],
            start_row: arguments['start_row'] || 1,
            max_rows: arguments['max_rows'] || 20,
            max_columns: arguments['max_columns'] || 12
          ).merge(file_name: file[:stored_name])
        end

        def extract_rows(arguments)
          workspace = workspace_from(arguments)
          file = workspace.resolve_upload(arguments['file_name'])
          document = SpreadsheetDocument.new(file[:path])
          document.extract_rows(
            sheet_name: arguments['sheet_name'],
            sheet_index: arguments['sheet_index'],
            header_row: arguments['header_row'] || 1,
            row_offset: arguments['row_offset'] || 0,
            row_limit: arguments['row_limit'] || 100,
            columns: arguments['columns']
          ).merge(file_name: file[:stored_name])
        end

        def export_report(arguments)
          workspace = workspace_from(arguments)
          rows = Array(arguments['rows'])
          raise ArgumentError, 'rows must not be empty' if rows.empty?

          columns = Array(arguments['columns']).map(&:to_s)
          raise ArgumentError, 'columns must not be empty' if columns.empty?

          workbook = SpreadsheetDocument.build_xlsx(
            sheet_name: arguments['sheet_name'] || 'Report',
            columns: columns,
            rows: rows,
            summary_lines: Array(arguments['summary_lines'])
          )

          report = workspace.save_report(
            file_name: arguments['file_name'],
            content: workbook
          )

          {
            file_name: report[:stored_name],
            row_count: rows.count,
            summary_line_count: Array(arguments['summary_lines']).count,
            download_path: report[:download_path],
            size_label: report[:size_label]
          }
        end

        def workspace_from(arguments)
          context = arguments['_chatbot_workspace']
          raise ArgumentError, 'Spreadsheet tools are only available inside chatbot sessions' unless context.is_a?(Hash)

          ChatbotWorkspace.new(
            user_id: context['user_id'] || context[:user_id],
            project_id: context['project_id'] || context[:project_id],
            session_id: context['session_id'] || context[:session_id]
          )
        end
      end
    end
  end
end
