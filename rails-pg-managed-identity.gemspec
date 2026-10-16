# frozen_string_literal: true

require_relative "lib/rails_pg/managed_identity/version"

Gem::Specification.new do |spec|
  spec.name = "rails-pg-managed-identity"
  spec.version = RailsPg::ManagedIdentity::VERSION
  spec.authors = ["Frederik Erbs Spang Thomsen"]
  spec.email = ["fst@last.dk"]

  spec.summary = "Azure managed identity (Microsoft Entra) authentication for Rails and Azure Database for PostgreSQL"
  spec.description = "Connects Active Record's PostgreSQL adapter to Azure Database for PostgreSQL flexible server " \
                     "with Microsoft Entra access tokens from managed identity, workload identity, a service " \
                     "principal or the Azure CLI. Tokens are fetched when connections are opened and refreshed " \
                     "before they expire, instead of a static password in database.yml."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"
  # Set these before publishing:
  spec.homepage = "https://github.com/frederikspang/rails-pg-managed-identity"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Overrides private adapter methods (see active_record_extensions.rb), so new majors need checking.
  spec.add_dependency "activerecord", ">= 7.2", "< 9"
  spec.add_dependency "pg", ">= 1.5"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
  spec.metadata["rubygems_mfa_required"] = "true"
end
