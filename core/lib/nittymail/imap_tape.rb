# frozen_string_literal: true

require "json"
require "ostruct"

module NittyMail
  class IMAPTape
    attr_reader :path, :data

    def initialize(path)
      @path = path
      @data = if File.exist?(path)
        JSON.parse(File.read(path))
      else
        {"preflight" => {}, "fetch" => {}}
      end
    end

    def save!
      dir = File.dirname(path)
      require "fileutils"
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
      File.write(path, JSON.pretty_generate(@data))
    end

    # Preflight
    def record_preflight(mailbox, result)
      @data["preflight"][mailbox.to_s] = result
      save!
    end

    def replay_preflight(mailbox)
      h = @data.fetch("preflight").fetch(mailbox.to_s)
      symbolize_keys(h)
    end

    # Fetch
    # uids_key can be like "1,2,3" or a range joined with '-'
    def record_fetch(mailbox, uids, attrs_list)
      @data["fetch"][mailbox.to_s] ||= {}
      safe_list = attrs_list.map do |item|
        raw = item["attr"] || {}
        encoded = {}
        raw.each do |k, v|
          encoded[k] = v.is_a?(String) ? {"__b64__" => [v].pack("m0")} : v
        end
        {"attr" => encoded}
      end
      @data["fetch"][mailbox.to_s][uids_key(uids)] = safe_list
      save!
    end

    def replay_fetch(mailbox, uids)
      list = @data.fetch("fetch").fetch(mailbox.to_s).fetch(uids_key(uids))
      list.map do |h|
        raw = h["attr"] || {}
        decoded = {}
        raw.each do |k, v|
          decoded[k] = (v.is_a?(Hash) && v.key?("__b64__")) ? v["__b64__"].unpack1("m0") : v
        end
        OpenStruct.new(attr: decoded)
      end
    end

    private

    def uids_key(uids)
      arr = Array(uids).map(&:to_i).sort
      if arr.size > 1 && arr.each_cons(2).all? { |a, b| b == a + 1 }
        "#{arr.first}-#{arr.last}"
      else
        arr.join(",")
      end
    end

    def symbolize_keys(obj)
      case obj
      when Array
        obj.map { |v| symbolize_keys(v) }
      when Hash
        obj.each_with_object({}) do |(k, v), acc|
          key = k.is_a?(String) ? k.to_sym : k
          acc[key] = symbolize_keys(v)
        end
      else
        obj
      end
    end
  end
end
