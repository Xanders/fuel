require "./spec_helper"

describe Fuel::Config do
  it "supports one explicit secret source and fails closed on missing or duplicate values" do
    name = "FUEL_SPEC_#{Fuel.id.upcase}"
    path = File.tempfile("fuel-secret") { |file| file.print("file-value\n") }.path
    begin
      expect_raises(Fuel::Error, "missing_secret") { Fuel::Config.secret(name) }
      Fuel::Config.secret(name, required: false).should be_nil
      ENV[name] = "direct-value"
      Fuel::Config.secret(name).should eq("direct-value")
      ENV["#{name}_FILE"] = path
      expect_raises(Fuel::Error, "duplicate_secret_source") { Fuel::Config.secret(name) }
      ENV.delete(name)
      Fuel::Config.secret(name).should eq("file-value")
    ensure
      ENV.delete(name)
      ENV.delete("#{name}_FILE")
      File.delete(path)
    end
  end
end
