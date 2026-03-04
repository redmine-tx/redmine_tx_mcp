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

      def log_api_call(data)
        lines = []
        lines << "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] === CHATBOT API CALL ==="
        lines << "session: #{data[:session_id]} | user: #{data[:user_name]} | model: #{data[:model]}"
        lines << "depth: #{data[:depth]}/#{data[:max_depth]} | stop_reason: #{data[:stop_reason]}"
        lines << "system_prompt: #{format_number(data[:system_prompt_chars])} chars | messages: #{data[:message_count]} (cleaned from #{data[:raw_message_count]})"
        lines << "tools_sent: #{data[:tools_count]} definitions"
        lines << "--- USAGE ---"
        lines << "input_tokens: #{format_number(data[:input_tokens])} | output_tokens: #{format_number(data[:output_tokens])}"
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log API call: #{e.message}"
      end

      def log_tool_execution(data)
        result_chars = data[:result_chars] || 0
        duration_ms = data[:duration_ms] || 0
        line = "  [tool] #{data[:tool_name]}(#{data[:tool_input]}) → #{format_number(result_chars)} chars, #{duration_ms}ms"
        logger.info(line)
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log tool execution: #{e.message}"
      end

      def log_session_summary(data)
        lines = []
        lines << ""
        lines << "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] === SESSION SUMMARY ==="
        lines << "session: #{data[:session_id]} | total_api_calls: #{data[:api_calls]} | total_tool_executions: #{data[:tool_executions]}"
        lines << "total_input_tokens: #{format_number(data[:input_tokens])} | total_output_tokens: #{format_number(data[:output_tokens])}"
        lines << "total_duration: #{data[:total_duration_ms]}ms"
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log session summary: #{e.message}"
      end

      private

      def format_number(n)
        return '0' if n.nil?
        n.to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\\1,')
      end
    end
  end
end
