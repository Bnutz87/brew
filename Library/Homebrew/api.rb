# typed: strict
# frozen_string_literal: true

require "api/analytics"
require "api/cask"
require "api/formula"
require "api/internal"
require "base64"

module Homebrew
  # Helper functions for using Homebrew's formulae.brew.sh API.
  module API
    extend Cachable

    HOMEBREW_CACHE_API = T.let((HOMEBREW_CACHE/"api").freeze, Pathname)
    HOMEBREW_CACHE_API_SOURCE = T.let((HOMEBREW_CACHE/"api-source").freeze, Pathname)
    TAP_MIGRATIONS_STALE_SECONDS = T.let(86400, Integer) # 1 day

    sig { params(endpoint: String).returns(T::Hash[String, T.untyped]) }
    def self.fetch(endpoint)
      return cache[endpoint] if cache.present? && cache.key?(endpoint)

      api_url = "#{Homebrew::EnvConfig.api_domain}/#{endpoint}"
      output = Utils::Curl.curl_output("--fail", api_url)
      if !output.success? && Homebrew::EnvConfig.api_domain != HOMEBREW_API_DEFAULT_DOMAIN
        # Fall back to the default API domain and try again
        api_url = "#{HOMEBREW_API_DEFAULT_DOMAIN}/#{endpoint}"
        output = Utils::Curl.curl_output("--fail", api_url)
      end
      raise ArgumentError, "No file found at #{Tty.underline}#{api_url}#{Tty.reset}" unless output.success?

      cache[endpoint] = JSON.parse(output.stdout, freeze: true)
    rescue JSON::ParserError
      raise ArgumentError, "Invalid JSON file: #{Tty.underline}#{api_url}#{Tty.reset}"
    end

    sig {
      params(endpoint: String, target: Pathname, stale_seconds: Integer, download_queue: T.nilable(DownloadQueue))
        .returns([T.any(T::Array[T.untyped], T::Hash[String, T.untyped]), T::Boolean])
    }
    def self.fetch_json_api_file(endpoint, target: HOMEBREW_CACHE_API/endpoint,
                                 stale_seconds: Homebrew::EnvConfig.api_auto_update_secs.to_i, download_queue: nil)
      # Lazy-load dependency.
      require "development_tools"

      retry_count = 0
      url = "#{Homebrew::EnvConfig.api_domain}/#{endpoint}"
      default_url = "#{HOMEBREW_API_DEFAULT_DOMAIN}/#{endpoint}"

      if Homebrew.running_as_root_but_not_owned_by_root? &&
         (!target.exist? || target.empty?)
        odie "Need to download #{url} but cannot as root! Run `brew update` without `sudo` first then try again."
      end

      curl_args = Utils::Curl.curl_args(retries: 0) + %W[
        --compressed
        --speed-limit #{ENV.fetch("HOMEBREW_CURL_SPEED_LIMIT")}
        --speed-time #{ENV.fetch("HOMEBREW_CURL_SPEED_TIME")}
      ]

      insecure_download = DevelopmentTools.ca_file_substitution_required? ||
                          DevelopmentTools.curl_substitution_required?
      skip_download = target.exist? &&
                      !target.empty? &&
                      (!Homebrew.auto_update_command? ||
                        (Homebrew::EnvConfig.no_auto_update? && !Homebrew::EnvConfig.force_api_auto_update?) ||
                      ((Time.now - stale_seconds) < target.mtime))
      skip_download ||= Homebrew.running_as_root_but_not_owned_by_root?

      if download_queue
        unless skip_download
          require "api/json_download"
          download = Homebrew::API::JSONDownload.new(endpoint, target:, stale_seconds:)
          download_queue.enqueue(download)
        end
        return [{}, false]
      end

      json_data = begin
        begin
          args = curl_args.dup
          args.prepend("--time-cond", target.to_s) if target.exist? && !target.empty?
          if insecure_download
            opoo DevelopmentTools.insecure_download_warning(endpoint)
            args.append("--insecure")
          end
          unless skip_download
            ohai "Downloading #{url}" if $stdout.tty? && !Context.current.quiet?
            # Disable retries here, we handle them ourselves below.
            Utils::Curl.curl_download(*args, url, to: target, retries: 0, show_error: false)
          end
        rescue ErrorDuringExecution
          if url == default_url
            raise unless target.exist?
            raise if target.empty?
          elsif retry_count.zero? || !target.exist? || target.empty?
            # Fall back to the default API domain and try again
            # This block will be executed only once, because we set `url` to `default_url`
            url = default_url
            target.unlink if target.exist? && target.empty?
            skip_download = false

            retry
          end

          opoo "#{target.basename}: update failed, falling back to cached version."
        end

        mtime = insecure_download ? Time.new(1970, 1, 1) : Time.now
        FileUtils.touch(target, mtime:) unless skip_download
        # Can use `target.read` again when/if https://github.com/sorbet/sorbet/pull/8999 is merged/released.
        JSON.parse(File.read(target, encoding: Encoding::UTF_8), freeze: true)
      rescue JSON::ParserError
        target.unlink
        retry_count += 1
        skip_download = false
        odie "Cannot download non-corrupt #{url}!" if retry_count > Homebrew::EnvConfig.curl_retries.to_i

        retry
      end

      if endpoint.end_with?(".jws.json")
        success, data = verify_and_parse_jws(json_data)
        unless success
          target.unlink
          odie <<~EOS
            Failed to verify integrity (#{data}) of:
              #{url}
            Potential MITM attempt detected. Please run `brew update` and try again.
          EOS
        end
        [data, !skip_download]
      else
        [json_data, !skip_download]
      end
    end

    sig {
      params(json:       T::Hash[String, T.untyped],
             bottle_tag: ::Utils::Bottles::Tag).returns(T::Hash[String, T.untyped])
    }
    def self.merge_variations(json, bottle_tag: T.unsafe(nil))
      return json unless json.key?("variations")

      bottle_tag ||= Homebrew::SimulateSystem.current_tag

      if (variation = json.dig("variations", bottle_tag.to_s).presence) ||
         (variation = json.dig("variations", bottle_tag.to_sym).presence)
        json = json.merge(variation)
      end

      json.except("variations")
    end

    sig { params(names: T::Array[String], type: String, regenerate: T::Boolean).returns(T::Boolean) }
    def self.write_names_file!(names, type, regenerate:)
      names_path = HOMEBREW_CACHE_API/"#{type}_names.txt"
      if !names_path.exist? || regenerate
        names_path.write(names.join("\n"))
        return true
      end

      false
    end

    sig {
      params(json_data: T::Hash[String, T.untyped])
        .returns([T::Boolean, T.any(String, T::Array[T.untyped], T::Hash[String, T.untyped])])
    }
    private_class_method def self.verify_and_parse_jws(json_data)
      signatures = json_data["signatures"]
      homebrew_signature = signatures&.find { |sig| sig.dig("header", "kid") == "homebrew-1" }
      return false, "key not found" if homebrew_signature.nil?

      header = JSON.parse(Base64.urlsafe_decode64(homebrew_signature["protected"]))
      if header["alg"] != "PS512" || header["b64"] != false # NOTE: nil has a meaning of true
        return false, "invalid algorithm"
      end

      require "openssl"

      pubkey = OpenSSL::PKey::RSA.new((HOMEBREW_LIBRARY_PATH/"api/homebrew-1.pem").read)
      signing_input = "#{homebrew_signature["protected"]}.#{json_data["payload"]}"
      unless pubkey.verify_pss("SHA512",
                               Base64.urlsafe_decode64(homebrew_signature["signature"]),
                               signing_input,
                               salt_length: :digest,
                               mgf1_hash:   "SHA512")
        return false, "signature mismatch"
      end

      [true, JSON.parse(json_data["payload"], freeze: true)]
    end

    sig { params(path: Pathname).returns(T.nilable(Tap)) }
    def self.tap_from_source_download(path)
      path = path.expand_path
      source_relative_path = path.relative_path_from(Homebrew::API::HOMEBREW_CACHE_API_SOURCE)
      return if source_relative_path.to_s.start_with?("../")

      org, repo = source_relative_path.each_filename.first(2)
      return if org.blank? || repo.blank?

      Tap.fetch(org, repo)
    end
  end

  sig { params(block: T.proc.returns(T.untyped)).returns(T.untyped) }
  def self.with_no_api_env(&block)
    return yield if Homebrew::EnvConfig.no_install_from_api?

    with_env(HOMEBREW_NO_INSTALL_FROM_API: "1", HOMEBREW_AUTOMATICALLY_SET_NO_INSTALL_FROM_API: "1", &block)
  end

  sig { params(condition: T::Boolean, block: T.proc.returns(T.untyped)).returns(T.untyped) }
  def self.with_no_api_env_if_needed(condition, &block)
    return yield unless condition

    with_no_api_env(&block)
  end
end
