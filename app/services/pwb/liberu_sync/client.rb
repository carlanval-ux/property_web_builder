# frozen_string_literal: true

require "net/http"
require "json"

module Pwb
  module LiberuSync
    # Reads Liberu's anonymous storefront API:
    #   GET {base_url}/api/v1/public/properties?page=N&page_size=60
    #
    # That endpoint only returns properties whose status is `available` or
    # `published` (PublicPropertyController in liberusoftware's
    # real-estate-properties-api), so drafts, moderation, withdrawn, sold...
    # never reach this client. Anything a previous run published and is now
    # missing from the full listing has left the public set in Liberu.
    class Client
      PAGE_SIZE = 60
      MAX_PAGES = 500

      def initialize(base_url:, open_timeout: 10, read_timeout: 30)
        raise ArgumentError, "LIBERU_API_URL is not set" if base_url.blank?

        @base_url = base_url.to_s.chomp("/")
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      # Returns every public property. Raises FetchError if any page fails, so
      # callers never mistake a partial listing for the complete public set.
      def fetch_all
        items = []
        page = 1
        loop do
          body = get_json("/api/v1/public/properties", page: page, page_size: PAGE_SIZE)
          data = body.fetch("data") { raise FetchError, "Unexpected payload: no data key on page #{page}" }
          items.concat(data)

          last_page = body.dig("meta", "last_page").to_i
          break if data.empty? || last_page.zero? || page >= last_page

          page += 1
          raise FetchError, "Pagination did not terminate after #{MAX_PAGES} pages" if page > MAX_PAGES
        end
        items
      end

      private

      def get_json(path, params)
        uri = URI.parse("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(params)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
          request = Net::HTTP::Get.new(uri)
          request["Accept"] = "application/json"
          http.request(request)
        end
        raise FetchError, "GET #{uri} -> HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue JSON::ParserError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
        raise FetchError, "GET #{uri}: #{e.class}: #{e.message}"
      end
    end
  end
end
