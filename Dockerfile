FROM ruby:2.3.1
MAINTAINER Scott Opell <me@scottopell.com>

RUN apt-get update && \
    apt-get install -y net-tools

ENV RACK_ENV production

# Install gems
ENV APP_HOME /app

RUN mkdir $APP_HOME
WORKDIR $APP_HOME

COPY Gemfile* $APP_HOME/

RUN bundle install

# Upload source
COPY . $APP_HOME

# Start server
ENV PORT 80
EXPOSE 80
CMD ["ruby", "server.rb"]
