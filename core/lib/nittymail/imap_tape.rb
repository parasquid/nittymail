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
      Dir.mkdir(dir) unless Dir.exist?(dir)
      File.write(path, JSON.pretty_generate(@data))
    end

    # Preflight
    def record_preflight(mailbox, result)
      @data["preflight"][mailbox.to_s] = result
      save!
    end

    def replay_preflight(mailbox)
      @data.fetch("preflight").fetch(mailbox.to_s)
    end

    # Fetch
    # uids_key can be like "1,2,3" or a range joined with '-'
    def record_fetch(mailbox, uids, attrs_list)
      @data["fetch"][mailbox.to_s] ||= {}
      @data["fetch"][mailbox.to_s][uids_key(uids)] = attrs_list
      save!
    end

    def replay_fetch(mailbox, uids)
      list = @data.fetch("fetch").fetch(mailbox.to_s).fetch(uids_key(uids))
      list.map { |h| OpenStruct.new(attr: symbolize_keys(h["attr"])) }
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

    def symbolize_keys(h)
      h.each_with_object({}) { |(k, v), acc| acc[k.is_a?(String) ? k.to_s : k] = v }
    end
  end
end
