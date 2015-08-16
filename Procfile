web: bundle exec unicorn --config-file config/unicorn.rb --host ${HOST:="127.0.0.1"} --port ${PORT:="9393"} --env ${RAILS_ENV:="production"}
worker: RAILS_ENV=production bundle exec rake jobs:work
