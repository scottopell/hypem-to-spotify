require_relative 'db_helpers.rb'

namespace :db do
  desc "Drop all data and create mongo collections with indices and validation"
  task :create do
    DBHelpers.create!
  end
end
