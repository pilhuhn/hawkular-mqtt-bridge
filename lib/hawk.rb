require 'rubygems'
require 'mqtt'
require 'hawkular_all'


INVENTORY_BASE = 'http://localhost:8080/hawkular/inventory'
METRICS_BASE = 'http://localhost:8080/hawkular/metrics'
CREDS = {username: 'jdoe', password: 'password'}
BROKER = 'snert'

@inv_client = Hawkular::Inventory::InventoryClient.new(INVENTORY_BASE, CREDS)
my_tenant = @inv_client.get_tenant
@metrics_client = Hawkular::Metrics::Client.new(METRICS_BASE, CREDS)

@queue = []

def process_metric(message)
  # data format is : id value [timestamp]
  fields = message.split(' ')

  if fields.size < 2
    puts 'Invalid record'
    return
  end

  data_point = {value: fields[1]}
  if fields.size ==3
    ts = fields[2]*1000 # incoming: seconds since epoch, required: ms
  else
    ts = Time.now.to_i * 1000 # current time in ms
  end

  data_point[timestamp: ts]
  data = [{id: fields[0], data: [data_point]}]
  begin
    @metrics_client.push_data(gauges: data)
    # There was data queued, send it now
    if @queue.size > 0
      @queue.each do |_entry|
        data = @queue.pop
        @metrics_client.push_data(gauges:data)
      end
    end
  rescue
    # Pushing failed -> we need to spool and try later
    @queue.push data
  end

end

def register_resource(_topic, message)
  puts 'Register ' + message

  return if message.nil? || message.empty?

  # "{\"feed\": \"mcu123\",\"rt\":\"esp8266\",\"r\":\"mcu123\"}"
  data = JSON.parse(message)

  puts '=> Data ' + data.to_s

  feed = data['feed']
  code = @inv_client.create_feed feed, feed # Set separate feed name
  puts 'Feed created: '

  type = @inv_client.create_resource_type feed, data['rt'], data['rt']
  type_path= type.path

  resource = @inv_client.create_resource feed, type_path, data['r'], data['r']

  m_type = data['mt']
  metric = data['m']

  d_type = m_type['type']
  unit = m_type['unit']
  metric_type = @inv_client.create_metric_type feed, m_type['id'], d_type, unit, m_type['collectionInterval']

  @inv_client.create_metric_for_resource feed, metric['id'], metric_type.path, resource.id, metric['na']

end


MQTT::Client.connect(BROKER) do |c|

  c.subscribe('/hawkular/+')

  # If you pass a block to the get method, then it will loop
  c.get('/hawkular/+') do |topic,message|
    puts "#{topic}: #{message}"

    process_metric(message) if topic.eql? '/hawkular/metrics'
    register_resource(topic, message) if topic.eql? '/hawkular/register'
  end
end


