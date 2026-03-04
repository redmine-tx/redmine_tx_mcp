require 'net/http'
require 'json'
require 'uri'

module RedmineTxMcp
  class AnthropicModelsService
    API_BASE = "https://api.anthropic.com"
    CACHE_KEY = "redmine_tx_mcp/anthropic_models"
    CACHE_TTL = 24.hours

    class << self
      def fetch_models(force_refresh: false)
        api_key = get_api_key
        return [] if api_key.blank?

        Rails.cache.delete(CACHE_KEY) if force_refresh

        Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
          fetch_all_models(api_key)
        end
      rescue => e
        Rails.logger.error "[AnthropicModelsService] #{e.class}: #{e.message}"
        []
      end

      private

      def get_api_key
        settings = Setting.plugin_redmine_tx_mcp rescue {}
        settings ||= {}
        key = settings['claude_api_key']
        key.presence || ENV['ANTHROPIC_API_KEY']
      end

      def fetch_all_models(api_key)
        models = []
        after_id = nil

        loop do
          data = fetch_page(api_key, after_id)
          break if data.nil?

          page_models = data['data'] || []
          models.concat(page_models)

          if data['has_more'] == true && data['last_id'].present?
            after_id = data['last_id']
          else
            break
          end
        end

        filter_and_format(models)
      end

      def fetch_page(api_key, after_id = nil)
        uri = URI("#{API_BASE}/v1/models")
        params = { limit: 1000 }
        params[:after_id] = after_id if after_id
        uri.query = URI.encode_www_form(params)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Get.new(uri)
        request['x-api-key'] = api_key
        request['anthropic-version'] = '2023-06-01'
        request['content-type'] = 'application/json'

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.error "[AnthropicModelsService] API returned #{response.code}: #{response.body}"
          return nil
        end

        JSON.parse(response.body)
      rescue => e
        Rails.logger.error "[AnthropicModelsService] HTTP error: #{e.class}: #{e.message}"
        nil
      end

      def filter_and_format(models)
        models
          .sort_by { |m| m['display_name'].to_s }
          .map { |m| { 'id' => m['id'], 'display_name' => m['display_name'] || m['id'] } }
      end
    end
  end
end
