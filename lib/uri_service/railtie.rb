class UriService::Railtie < Rails::Railtie
  initializer "uri_service_railtie.configure_rails_initialization" do
    UriService::init(YAML.load_file("#{Rails.root.to_s}/config/uri_service.yml")[Rails.env])
    
    unless UriService.client.connected?
      Rails.logger.error "Could not connect to UriService.  Verify config in config/uri_service.yml file."
    end
    
    unless UriService.client.required_tables_exist?
      Rails.logger.error "\n-----\nWARNING: Required UriService database tables not found.  \n\nRun: bundle exec rake uri_service:db:setup" + "\n-----\n\n"
    end
  end
  
  rake_tasks do
    Dir.glob(File.join(File.dirname(__FILE__), '../tasks/**/*.rake')).each do |rakefile|
      load rakefile unless rakefile.end_with?('ci.rake')  # The ci rakefile has require statements that
                                                          # are only development dependencies, so that
                                                          # file shouldn't be pulled into a Rails app.
    end
  end
end