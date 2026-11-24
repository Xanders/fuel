module Fuel
  record SessionEvent, id : String, actor : String, name : String, properties : JSON::Any,
    occurred_at : Int64, revision : Int64? = nil

  # One collector belongs to one candidate room mutation. Fuel freezes the first
  # accepted occurrence per actor/name/discriminator for the room lifetime.
  class SessionEvents
    @facts = {} of String => SessionEvent

    def initialize(@occurred_at : Int64)
    end

    def once(actor : String, name : String, properties : JSON::Any, discriminator : String = "")
      Fuel.key(actor)
      Fuel.key(name)
      return if @facts.size >= 256 || discriminator.bytesize > 100
      encoded = properties.to_json
      return if encoded.bytesize > 2048
      id = Digest::SHA256.hexdigest({actor, name, discriminator}.to_json)
      @facts[id] ||= SessionEvent.new(id, actor, name, JSON.parse(encoded), @occurred_at)
    rescue Error | JSON::Error
      # Invalid telemetry never rejects the surrounding gameplay mutation.
      nil
    end

    def facts : Array(SessionEvent)
      @facts.values
    end
  end
end
