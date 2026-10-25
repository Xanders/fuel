module Fuel
  # One collector belongs to one candidate room mutation. Fuel freezes the first
  # accepted occurrence per actor/name/discriminator for the room lifetime.
  class SessionEvents
    @facts = {} of String => Effect

    def initialize(@occurred_at : Int64)
    end

    def once(actor : String, name : String, properties : JSON::Any, discriminator : String = "")
      Fuel.key(name)
      Fuel.check(properties.to_json.bytesize <= 2048 && discriminator.bytesize <= 100, "invalid_event")
      id = Digest::SHA256.hexdigest({actor, name, discriminator}.to_json)
      @facts[id] ||= Effect.new(id, actor, "_fuel_event", Fuel.json({name: name, properties: properties}), @occurred_at)
    end

    def facts : Array(Effect)
      @facts.values
    end
  end
end
