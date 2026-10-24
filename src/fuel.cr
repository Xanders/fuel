require "json"
require "random/secure"
require "digest/sha256"
require "uri"
require "set"
require "./fuel/*"

module Fuel
  VERSION = "0.1.0"

  class Error < Exception
    getter code : String

    def initialize(@code : String)
      super(@code)
    end
  end

  def self.check(condition : Bool, code : String)
    raise Error.new(code) unless condition
  end

  def self.json(value) : JSON::Any
    JSON.parse(value.to_json)
  end

  def self.id : String
    Random::Secure.hex(16)
  end

  def self.key(value : String)
    check(value.matches?(/\A[a-zA-Z0-9_-]{1,100}\z/), "invalid_key")
  end
end
