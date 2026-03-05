require 'logger'
require 'fileutils'

module RedmineTxMcp
  class ChatbotLogger
    LOG_FILE = File.join(Rails.root, 'log', 'chatbot_detail.log')

    class << self
      def logger
        @logger ||= begin
          FileUtils.mkdir_p(File.dirname(LOG_FILE))
          l = Logger.new(LOG_FILE, 'daily')
          l.progname = 'ChatbotDetail'
          l.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
          l
        end
      end

      def log_user_query(data)
        lines = []
        lines << ""
        lines << "[#{timestamp}] >>>>>> USER QUERY >>>>>>"
        lines << "session: #{data[:session_id]} | user: #{data[:user_name]}"
        lines << data[:message].to_s
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log user query: #{e.message}"
      end

      def log_api_call(data)
        lines = []
        lines << "[#{timestamp}] === CHATBOT API CALL ==="
        lines << "session: #{data[:session_id]} | user: #{data[:user_name]} | model: #{data[:model]}"
        lines << "loop_depth: #{data[:loop_depth]}/#{data[:max_depth]} | stop_reason: #{data[:stop_reason]}"
        lines << "system_prompt: #{format_number(data[:system_prompt_chars])} chars | messages: #{data[:message_count]} (from #{data[:raw_message_count]} raw, budget kept #{data[:budget_message_count] || '?'})"
        lines << "tools_sent: #{data[:tools_count]} definitions#{data[:tool_names] ? " [#{data[:tool_names]}]" : ''}"
        lines << "--- USAGE ---"
        lines << "input_tokens: #{format_number(data[:input_tokens])} | output_tokens: #{format_number(data[:output_tokens])}"
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log API call: #{e.message}"
      end

      def log_tool_execution(data)
        result_chars = data[:result_chars] || 0
        truncated_chars = data[:truncated_chars]
        duration_ms = data[:duration_ms] || 0
        trunc_info = truncated_chars ? " → truncated to #{format_number(truncated_chars)}" : ""

        lines = []
        lines << "  [tool] #{data[:tool_name]}(#{data[:tool_input]}) → #{format_number(result_chars)} chars#{trunc_info}, #{duration_ms}ms"
        lines << "  ---- result ----"
        lines << indent(data[:result_text].to_s, "  | ")
        lines << "  ---- end ----"
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log tool execution: #{e.message}"
      end

      def log_assistant_response(data)
        lines = []
        lines << ""
        lines << "[#{timestamp}] <<<<<< ASSISTANT RESPONSE <<<<<<"
        lines << "session: #{data[:session_id]}"
        lines << data[:message].to_s
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log assistant response: #{e.message}"
      end

      def log_session_summary(data)
        lines = []
        lines << ""
        lines << "[#{timestamp}] === SESSION SUMMARY ==="
        lines << "session: #{data[:session_id]} | api_calls: #{data[:api_calls]} | tool_executions: #{data[:tool_executions]}"
        lines << "input_tokens: #{format_number(data[:input_tokens])} | output_tokens: #{format_number(data[:output_tokens])}"
        lines << "total_duration: #{data[:total_duration_ms]}ms"
        lines << "history_messages: #{data[:history_message_count] || '?'} | history_chars: #{format_number(data[:history_chars] || 0)}"
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log session summary: #{e.message}"
      end

      private

      def timestamp
        Time.now.strftime('%Y-%m-%d %H:%M:%S')
      end

      def format_number(n)
        return '0' if n.nil?
        n.to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\\1,')
      end

      def indent(text, prefix)
        text.each_line.map { |line| "#{prefix}#{line.rstrip}" }.join("\n")
      end
    end
  end
end
