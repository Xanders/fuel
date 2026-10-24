module Fuel
  class NameDictionary
    def self.from_json(text : String) : NameDictionary
      new(JSON.parse(text))
    end

    def initialize(@data : JSON::Any)
      validate
    end

    private def validate
      Fuel.check(@data["version"].as_i == 1, "invalid_dictionary")
      locales = @data["locales"].as_h
      Fuel.check(locales.size <= 100 && locales.has_key?(@data["fallback"].as_s), "invalid_dictionary")
      locales.each_value do |pools|
        Fuel.check((1..8).includes?(pools.as_a.size), "invalid_dictionary")
        pools.as_a.each do |pool|
          Fuel.check((1..10000).includes?(pool.as_a.size), "invalid_dictionary")
          pool.as_a.each { |s| Fuel.check(!s.as_s.strip.empty? && s.as_s.size <= 40, "invalid_dictionary") }
        end
      end
    rescue TypeCastError | KeyError
      raise Error.new("invalid_dictionary")
    end

    def generate(seed : String, locale = "en") : String
      locale = locale.downcase.tr("_", "-")
      locales = @data["locales"].as_h
      pools = locales[locale]? || locales[locale.split('-').first]? || locales[@data["fallback"].as_s]
      separator = @data["separator"]?.try(&.as_s) || " "
      pools.as_a.map_with_index do |pool, index|
        digest = Digest::SHA256.hexdigest({1, seed, index}.to_json)
        pool.as_a[digest[0, 8].to_u32(16) % pool.as_a.size].as_s
      end.join(separator)
    end
  end

  class Censor
    @pattern : Regex?

    def initialize(words : Array(String), variants = {} of String => String)
      Fuel.check(words.size <= 10000 && words.all? { |w| !w.empty? && w.size <= 80 }, "invalid_dictionary")
      patterns = words.map do |word|
        letters = word.each_char.map { |c| "[#{Regex.escape(c.to_s + (variants[c.to_s]? || ""))}]" }.join("[^\\p{L}\\p{N}]*")
        "(?<![\\p{L}\\p{N}_])#{letters}(?![\\p{L}\\p{N}_])"
      end
      @pattern = words.empty? ? nil : Regex.new(patterns.join('|'), Regex::Options::IGNORE_CASE)
    end

    def filter(text : String) : String
      if pattern = @pattern
        text.gsub(pattern) { |word| "*" * word.size }
      else
        text
      end
    end
  end

  class Chat
    @history = {} of String => Array(JSON::Any)
    @mutex = Mutex.new
    @authorize : Proc(String, String, String, Bool)

    def initialize(@history_limit = 50, @max_channels = 2000, @ttl = 24.hours, @censor = Censor.new([] of String), @store : Store? = nil, @persist = [] of String, &@authorize : String, String, String -> Bool)
      Fuel.check((0..1000).includes?(@history_limit) && @max_channels > 0, "invalid_capacity")
      Fuel.check(@persist.all? { |kind| ["private", "guild"].includes?(kind) } && (@persist.empty? || !@store.nil?), "invalid_channel")
    end

    def post(actor : String, kind : String, target : String, text : String) : JSON::Any
      authorize(actor, kind, target)
      Fuel.check(!text.strip.empty? && text.bytesize <= 2000 && text.each_char.none? { |c| c.control? && c != '\n' }, "invalid_message")
      entry = Fuel.json({id: Fuel.id, actor: actor, text: @censor.filter(text.strip), created_at: Time.utc.to_unix})
      if @persist.includes?(kind)
        @store.not_nil!.save_chat(key(actor, kind, target), actor, kind == "private" ? target : "", entry, @history_limit, @ttl)
        return entry
      end
      @mutex.synchronize do
        cleanup
        k = key(actor, kind, target)
        Fuel.check(@history.has_key?(k) || @history.size < @max_channels, "capacity")
        history = @history[k] ||= [] of JSON::Any
        history << entry if @history_limit > 0
        while history.size > @history_limit
          history.shift
        end
      end
      entry
    end

    def history(actor : String, kind : String, target : String) : Array(JSON::Any)
      authorize(actor, kind, target)
      if @persist.includes?(kind)
        return @store.not_nil!.read_chat(key(actor, kind, target), @history_limit, @ttl)
      end
      @mutex.synchronize do
        cleanup
        (@history[key(actor, kind, target)]? || [] of JSON::Any).map { |e| JSON.parse(e.to_json) }
      end
    end

    private def authorize(actor, kind, target)
      Fuel.check(["global", "session", "guild", "private"].includes?(kind), "invalid_channel")
      Fuel.check(target.bytesize <= 100 && actor != target, "invalid_channel")
      Fuel.check(kind == "private" || @authorize.call(actor, kind, target), "forbidden")
    end

    private def key(actor, kind, target) : String
      {kind, kind == "private" ? [actor, target].sort.join(':') : target}.to_json
    end

    private def cleanup
      cutoff = Time.utc.to_unix - @ttl.total_seconds.to_i64
      @history.each_value { |v| v.reject! { |m| m["created_at"].as_i64 < cutoff } }
      @history.reject! { |_, v| v.empty? }
    end
  end
end
