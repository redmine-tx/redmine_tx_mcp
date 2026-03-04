module RedmineTxMcp
  module Tools
    class BaseTool
      class << self
        def available_tools
          []
        end

        def call_tool(tool_name, arguments)
          { error: "Tool not implemented: #{tool_name}" }
        end

        protected

        def format_response(data)
          if data.respond_to?(:attributes)
            data.attributes.merge(
              'id' => data.id,
              'created_on' => data.created_on&.iso8601,
              'updated_on' => data.updated_on&.iso8601
            )
          elsif data.is_a?(Array)
            data.map { |item| format_response(item) }
          else
            data
          end
        end

        def paginate_results(collection, page: 1, per_page: 25)
          page = [page.to_i, 1].max
          per_page = [[per_page.to_i, 1].max, 100].min

          total = collection.count
          offset = (page - 1) * per_page
          items = collection.offset(offset).limit(per_page)

          {
            items: format_response(items.to_a),
            pagination: {
              page: page,
              per_page: per_page,
              total_count: total,
              total_pages: (total.to_f / per_page).ceil
            }
          }
        end

        def handle_error(error)
          Rails.logger.error "MCP Tool Error: #{error.message}"
          Rails.logger.error error.backtrace.join("\n")
          { error: error.message }
        end
      end
    end
  end
end