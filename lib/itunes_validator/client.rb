require 'json'
require 'net/https'
require 'uri'

module ItunesValidator
  APPSTORE_VERIFY_URL_PRODUCTION = 'https://buy.itunes.apple.com/verifyReceipt'
  APPSTORE_VERIFY_URL_SANDBOX = 'https://sandbox.itunes.apple.com/verifyReceipt'

  def self.validate(options=nil, receipt_data)
    v = Client.new(options)
    v.validate(receipt_data)
  end

  class Client
    def initialize(options=nil)
      @shared_secret = options[:shared_secret] if options
      @use_latest = (true unless options && options.has_key?(:use_latest)) || !!options[:use_latest]
      @return_latest_too = (true unless options && options.has_key?(:return_latest_too)) || !!options[:return_latest_too]
      @proxy = [options[:proxy_host], options[:proxy_port] || 8080] if (options && options[:proxy_host])
    end

    def validate(receipt_data)
      raise ParameterError unless (receipt_data && !receipt_data.strip.empty?)

      post_body = { 'receipt-data' => receipt_data }
      post_body['password'] = @shared_secret if @shared_secret && !@shared_secret.strip.empty?

      receipt_info = latest_receipt_info = nil

      uri = URI(APPSTORE_VERIFY_URL_PRODUCTION)
      begin
        h = @proxy ? Net::HTTP::Proxy(*@proxy) : Net::HTTP
        h.start(uri.host, uri.port, use_ssl: true) do |http|
          req = Net::HTTP::Post.new(uri.request_uri, {'Accept' => 'application/json', 'Content-Type'=>'application/json'})
          req.body = post_body.to_json

          response = http.request(req)
          raise ItunesCommunicationError.new(response.code) unless response.code == '200'
          response_body = JSON.parse(response.body)

          case itunes_status = response_body['status'].to_i
            when 0
              receipt_info = response_body['receipt']
              latest_receipt_info = response_body['latest_receipt_info']
            else
              raise ItunesValidationError.new(itunes_status)
          end
        end
      rescue ItunesCommunicationError
      rescue ItunesValidationError => e
        case e.code
          when 21007
            uri = URI(APPSTORE_VERIFY_URL_SANDBOX)
            retry
        end
      end

      is_new_style = receipt_info.has_key?('in_app')

      if is_new_style then
        receipts = {
          'receipt' => AppReceipt.from_h(receipt_info),
          'latest_receipt_info' => latest_receipt_info.map{ |ri| ItemReceipt.from_h(ri) if ri },
        }
      else
        receipt = LegacyIapReceipt.from_h(receipt_info) if receipt_info
        latest_receipt = LegacyIapReceipt.from_h(latest_receipt_info) if latest_receipt_info
        receipts = {
          'receipt' => receipt,
          'latest_receipt_info' => [receipt, latest_receipt],
        }
      end

      if @use_latest
        return receipts['latest_receipt_info'].compact.last
      end

      if @return_latest_too
        return receipts
      end

      receipts['receipt']
    end
  end

  class Error < StandardError
  end

  class ParameterError < Error
  end

  class ItunesCommunicationError < Error
    def initialize(code)
      @code = code
    end

    attr_reader :code
  end

  class ItunesValidationError < Error
    def initialize(code)
      @code = code
    end

    attr_reader :code
  end
end
