#!/usr/bin/ruby
#
# Copyright Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

require 'webrick'
require 'json'
require 'net/http'

require 'opentelemetry-sdk'
require 'opentelemetry-propagator-b3'
require 'opentelemetry-exporter-otlp'

OpenTelemetry::SDK.configure do |c|
    c.http_extractors = [OpenTelemetry::Propagator::B3::Single.rack_extractor, OpenTelemetry::Propagator::B3::Multi.rack_extractor]
    c.http_injectors = [OpenTelemetry::Propagator::B3::Single.rack_injector]
    c.text_map_extractors = [OpenTelemetry::Propagator::B3::Single.text_map_extractor, OpenTelemetry::Propagator::B3::Multi.text_map_extractor]
    c.text_map_injectors = [OpenTelemetry::Propagator::B3::Single.text_map_injector]
end
 
if ARGV.length < 1 then
    puts "usage: #{$PROGRAM_NAME} port"
    exit(-1)
end

port = Integer(ARGV[0])

server = WEBrick::HTTPServer.new :BindAddress => '*', :Port => port

trap 'INT' do server.shutdown end

server.mount_proc '/health' do |req, res|
    res.status = 200
    res.body = {'status' => 'Details is healthy'}.to_json
    res['Content-Type'] = 'application/json'
end

server.mount_proc '/details' do |req, res|
    pathParts = req.path.split('/')
    headers = req.header

    begin
        begin
          id = Integer(pathParts[-1])
        rescue
          raise 'please provide numeric product id'
        end
        details = get_book_details(id, headers)
        res.body = details.to_json
        res['Content-Type'] = 'application/json'
    rescue => error
        res.body = {'error' => error}.to_json
        res['Content-Type'] = 'application/json'
        res.status = 400
    end
end

# TODO: provide details on different books.
def get_book_details(id, headers)
    if ENV['ENABLE_EXTERNAL_BOOK_SERVICE'] === 'true' then
      # the ISBN of one of Comedy of Errors on the Amazon
      # that has Shakespeare as the single author
        isbn = '0486424618'
        return fetch_details_from_external_service(isbn, id, headers)
    end

    return {
        'id' => id,
        'author': 'William Shakespeare',
        'year': 1595,
        'type' => 'paperback',
        'pages' => 200,
        'publisher' => 'PublisherA',
        'language' => 'English',
        'ISBN-10' => '1234567890',
        'ISBN-13' => '123-1234567890'
    }
end

def fetch_details_from_external_service(isbn, id, headers)
    uri = URI.parse('https://www.googleapis.com/books/v1/volumes?q=isbn:' + isbn)
    http = Net::HTTP.new(uri.host, ENV['DO_NOT_ENCRYPT'] === 'true' ? 80:443)
    http.read_timeout = 5 # seconds

    # DO_NOT_ENCRYPT is used to configure the details service to use either
    # HTTP (true) or HTTPS (false, default) when calling the external service to
    # retrieve the book information.
    #
    # Unless this environment variable is set to true, the app will use TLS (HTTPS)
    # to access external services.
    unless ENV['DO_NOT_ENCRYPT'] === 'true' then
      http.use_ssl = true
    end

    request = Net::HTTP::Get.new(uri.request_uri)
    headers.each { |header, value| request[header] = value }

    response = http.request(request)

    json = JSON.parse(response.body)
    book = json['items'][0]['volumeInfo']

    language = book['language'] === 'en'? 'English' : 'unknown'
    type = book['printType'] === 'BOOK'? 'paperback' : 'unknown'
    isbn10 = get_isbn(book, 'ISBN_10')
    isbn13 = get_isbn(book, 'ISBN_13')

    return {
        'id' => id,
        'author': book['authors'][0],
        'year': book['publishedDate'],
        'type' => type,
        'pages' => book['pageCount'],
        'publisher' => book['publisher'],
        'language' => language,
        'ISBN-10' => isbn10,
        'ISBN-13' => isbn13
  }

end

def get_isbn(book, isbn_type)
  isbn_dentifiers = book['industryIdentifiers'].select do |identifier|
    identifier['type'] === isbn_type
  end

  return isbn_dentifiers[0]['identifier']
end

server.start
