module Fuel
  module Config
    def self.secret(name : String) : String
      secret(name, required: true).not_nil!
    end

    def self.secret(name : String, *, required : Bool) : String?
      direct = ENV[name]?.try(&.strip).try { |value| value.empty? ? nil : value }
      file = ENV["#{name}_FILE"]?.try(&.strip).try { |value| value.empty? ? nil : value }
      Fuel.check(direct.nil? || file.nil?, "duplicate_secret_source")
      value = file ? File.read(file).strip : direct
      value = nil if value.try(&.empty?)
      Fuel.check(!required || !value.nil?, "missing_secret")
      value
    end
  end
end
