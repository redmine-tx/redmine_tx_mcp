require 'net/http'
require 'json'
require 'uri'

module RedmineTxMcp
  class OpenaiModelsService
    CACHE_KEY = "redmine_tx_mcp/openai_models"
    CACHE_TTL = 24.hours

    class << self
      def fetch_models(endpoint_url:, api_key: nil, force_refresh: false)
        return [] if endpoint_url.blank?

        cache_key = "#{CACHE_KEY}/#{Digest::MD5.hexdigest(endpoint_url)}"
        Rails.cache.delete(cache_key) if force_refresh

        Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
          fetch_from_api(endpoint_url, api_key)
        end
      rescue => e
        Rails.logger.error "[OpenaiModelsService] #{e.class}: #{e.message}"
        []
      end

      private

      def fetch_from_api(endpoint_url, api_key)
        models_url = derive_models_url(endpoint_url)
        uri = URI(models_url)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Get.new(uri)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{api_key}" if api_key.present?

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.error "[OpenaiModelsService] API returned #{response.code}: #{response.body}"
          return []
        end

        data = JSON.parse(response.body)
        models = data['data'] || data['models'] || []

        models
          .sort_by { |m| m['id'].to_s }
          .map { |m| { 'id' => m['id'], 'display_name' => m['id'] } }
      rescue => e
        Rails.logger.error "[OpenaiModelsService] HTTP error: #{e.class}: #{e.message}"
        []
      end

      # Derive /v1/models URL from a chat completions endpoint URL.
      # e.g. http://localhost:11434/v1/chat/completions → http://localhost:11434/v1/models
      def derive_models_url(endpoint_url)
        uri = URI(endpoint_url)
        path = uri.path

        if path.include?('/chat/completions')
          uri.path = path.sub(%r{/chat/completions.*}, '/models')
        elsif path.include?('/completions')
          uri.path = path.sub(%r{/completions.*}, '/models')
        else
          uri.path = path.sub(%r{/[^/]*$}, '/models')
        end

        uri.to_s
      end
    end
  end
end
