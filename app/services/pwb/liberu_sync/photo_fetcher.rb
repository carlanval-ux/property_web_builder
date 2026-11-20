# frozen_string_literal: true

require "net/http"
require "stringio"

module Pwb
  module LiberuSync
    # Fetches a Liberu gallery image so PWB stores its own copy (ActiveStorage),
    # instead of hot-linking the backoffice.
    #
    # When LIBERU_MEDIA_ROOT points at Liberu's public storage volume (mounted
    # read-only into the PWB containers) and the URL is under
    # "#{LIBERU_PUBLIC_URL}/storage/", the file is read from disk. Any other URL
    # is downloaded over HTTP(S).
    class PhotoFetcher
      MAX_BYTES = 20 * 1024 * 1024
      MAX_REDIRECTS = 3

      Photo = Struct.new(:io, :filename, :content_type, keyword_init: true)

      def initialize(public_url: ENV["LIBERU_PUBLIC_URL"], media_root: ENV["LIBERU_MEDIA_ROOT"])
        @storage_prefix = public_url.present? ? "#{public_url.to_s.chomp('/')}/storage/" : nil
        @media_root = media_root.present? ? File.expand_path(media_root) : nil
      end

      def fetch(url)
        bytes = local_bytes(url) || http_bytes(url)
        raise FetchError, "Photo larger than #{MAX_BYTES} bytes: #{url}" if bytes.bytesize > MAX_BYTES

        filename = File.basename(URI.parse(url).path.to_s).presence || "photo.jpg"
        content_type = Marcel::MimeType.for(StringIO.new(bytes), name: filename)
        raise FetchError, "Not an image (#{content_type}): #{url}" unless content_type.to_s.start_with?("image/")

        Photo.new(io: StringIO.new(bytes), filename: filename, content_type: content_type)
      end

      private

      def local_bytes(url)
        return nil unless @storage_prefix && @media_root && url.start_with?(@storage_prefix)

        relative = URI::DEFAULT_PARSER.unescape(url.delete_prefix(@storage_prefix).split("?").first.to_s)
        path = File.expand_path(relative, @media_root)
        raise FetchError, "Path escapes media root: #{url}" unless path.start_with?("#{@media_root}/")
        raise FetchError, "Photo not found on Liberu volume: #{relative}" unless File.file?(path)

        File.binread(path)
      end

      def http_bytes(url, redirects = 0)
        uri = URI.parse(url)
        raise FetchError, "Unsupported photo URL: #{url}" unless %w[http https].include?(uri.scheme)

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 60) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end

        case response
        when Net::HTTPSuccess
          response.body.to_s.b
        when Net::HTTPRedirection
          raise FetchError, "Too many redirects: #{url}" if redirects >= MAX_REDIRECTS

          http_bytes(URI.join(url, response["location"]).to_s, redirects + 1)
        else
          raise FetchError, "GET #{url} -> HTTP #{response.code}"
        end
      rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
        raise FetchError, "GET #{url}: #{e.class}: #{e.message}"
      end
    end
  end
end
