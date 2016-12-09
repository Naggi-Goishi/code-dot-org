# require_relative 'minimal_rails_env'
ROOT = File.expand_path('../../../../..', __FILE__)

# Fake Rails application, needed before initializers and after the prior requires.
module DashboardHelpers
  # Use require_rails_models or require_i18n instead.
  # This should not be needed anymore.
  #
  # Requires the full rails environment. Use sparingly, known to take several minutes in certain contexts.
  def require_rails_env
    require File.expand_path('../../../../config/environment.rb', __FILE__)
  end

  # Requires the i18n translations.
  def require_i18n
    require 'i18n'
    require 'yaml'
    require 'active_support'
    require 'active_support/core_ext'

    I18n.load_path.concat Dir.glob(File.join(ROOT, 'dashboard/config/locales/**/*.{rb,yml}'))
    I18n.available_locales = ['en']
    locales = YAML.load_file(File.join(ROOT, 'dashboard/config/locales.yml'))
    locales = Hash[locales.map {|k, v| [k.downcase, v.class == String ? v.downcase : v]}]
    locales.each do |locale, data|
      I18n.available_locales << locale
      next unless data.is_a? Hash
      data.symbolize_keys!
    end
    I18n.default_locale = 'en-us'
  end

  # Requires Rails models without loading the entire Rails environment (much faster).
  def require_rails_models
    prepend_load_paths 'dashboard', 'dashboard/lib', 'lib'

    # Require basic Rails support without
    require 'action_dispatch'
    require 'active_record'
    require 'active_support'
    require_relative File.expand_path(File.join(ROOT, 'deployment'))

    # Explicitly require gems needed by the models
    # [Andrew 2016-12-08] I spent some time messing with ActiveSupport::Dependencies.autoload_paths and couldn't
    # get it to work implicitly.
    require 'acts_as_list'
    require 'cancan'
    require 'retryable'
    require 'seamless_database_pool'
    require 'no_utf8mb4_validator'
    require 'validates_email_format_of'
    require 'app/helpers/locale_helper'
    require 'paranoia'
    require 'devise'
    require 'devise_invitable'

    # Stub Rails.application.routes to return an empty RouteSet.
    # No routes are loaded (or needed) in this context, but some models implicitly call this method.
    ::Rails.define_singleton_method(:application) do
      @@app ||= OpenStruct.new({
        routes: ActionDispatch::Routing::RouteSet.new
      })
    end

    # Stub Rails.root
    ::Rails.define_singleton_method(:root) do
      @@rails_root ||= File.expand_path(File.join(ROOT, 'dashboard'))
    end

    # Load necessary initializers
    require 'config/initializers/devise'

    # Configure DB connection
    db_config = YAML.load(ERB.new(File.read("#{Rails.root}/config/database.yml")).result)
    ActiveRecord::Base.establish_connection db_config[Rails.env]

    # Finally, load all the models
    require_dirs File.join(ROOT, 'dashboard/app/helpers'), File.join(ROOT, 'dashboard/app/models')
  end

  private

  # Prepend a set of paths to the $LOAD_PATHS (where Ruby looks for dependencies),
  # as long as it's not already in the list.
  def prepend_load_paths(*paths, absolute_path: false)
    paths.each do |path|
      path = File.expand_path(File.join(ROOT, path)) unless absolute_path
      next if $LOAD_PATH.include? path
      $LOAD_PATH.unshift path
    end
  end

  # Require every file .rb in a set of directories, recursively.
  # These files may depend on each other, so ignore NameErrors and keep trying as long
  # as at least one additional file is included on each attempt.
  def require_dirs(*dirs)
    files = []
    dirs.each do |dir|
      prepend_load_paths dir, absolute_path: true
      files.concat Dir.glob(File.join(dir, '**/*.rb'))
    end

    last_count = 0
    loop do
      last_count = files.count
      files.each do |file|
        begin
          require file
          files.delete file
        rescue NameError
          # Ignore. It has a missing dependency. Try again next round.
        end
      end

      # Keep trying as long as at least one additional model is successfully loaded
    end while files.count < last_count

    unless files.empty?
      # This will re-throw the error that prevented the file from loading above.
      require files.first
    end
  end
end

World(DashboardHelpers)
