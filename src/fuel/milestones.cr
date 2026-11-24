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
      Fuel.key(name)
      return if @facts.size >= 256 || properties.to_json.bytesize > 2048 || discriminator.bytesize > 100
      id = Digest::SHA256.hexdigest({actor, name, discriminator}.to_json)
      @facts[id] ||= SessionEvent.new(id, actor, name, JSON.parse(properties.to_json), @occurred_at)
    rescue Error
      # Invalid telemetry never rejects the surrounding gameplay mutation.
      nil
    end

    def facts : Array(SessionEvent)
      @facts.values
    end
  end
end
