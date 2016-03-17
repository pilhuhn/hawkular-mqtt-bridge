require 'rubygems'
require 'mqtt'
require 'YAML'
require 'hawkular_all'

#----------put your settings here ----
HAWKULAR_BASE = 'http://localhost:8080/hawkular'
CREDS = {username: 'jdoe', password: 'password'}
BROKER = 'snert'
@webhook_props = { url: 'http://172.31.7.177/',
                   method: 'POST' }

#--------------------------------------

INVENTORY_BASE = "#{HAWKULAR_BASE}/inventory"
METRICS_BASE = "#{HAWKULAR_BASE}/metrics"
ALERTS_BASE = "#{HAWKULAR_BASE}/alerts"

hash={:credentials => CREDS}
@inv_client = Hawkular::Inventory::InventoryClient.new(hash)
@metrics_client = Hawkular::Metrics::Client.new(METRICS_BASE, CREDS)
@alerts_client = Hawkular::Alerts::AlertsClient.new(ALERTS_BASE, CREDS)

@queue = []

def help_and_exit(extras=nil)
  puts extras unless extras.nil?
  puts 'Usage: ruby hawk.rb <config_file>'
  exit 1
end


help_and_exit if $*.length < 1
config_path = $*[0]
help_and_exit "#{config_path} is not readable" unless File.readable?(config_path)

@config = YAML.load_file(config_path)

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
  @inv_client.create_feed feed, feed # Set separate feed name
  puts 'Feed created: '

  type = @inv_client.create_resource_type feed, data['rt'], data['rt']
  type_path= type.path

  resource = @inv_client.create_resource feed, type_path, data['r'], data['r']

  m_type = data['mt']
  metric = data['m']

  d_type = m_type['type']
  unit = m_type['unit']
  metric_type = @inv_client.create_metric_type feed, m_type['id'], d_type, unit, m_type['collectionInterval']

  metric_id = metric['id']

  # check if we have an override
  m_def = @config.fetch metric_id if @config.key?( metric_id)
#  name = m_def.key?(:name) ? m_def.fetch(:name) : metric['na']
  name = metric['na'] # There is bug in the explorer :-(

  @inv_client.create_metric_for_resource feed, metric_id, metric_type.path, resource.id, name

  # As we want a longer TTL, we also need to register in metrics for now :-(
  # we chose 90 days retention
  begin
    @metrics_client.gauges.create(id: metric_id, dataRetention:90)
  rescue Exception => e
    puts e.to_s
  end

  register_alert feed, resource.id, metric_id, m_def, name if m_def.key?(:alert)
end

def register_alert(feed, res_id, metric_id, m_def, name)

  alert = m_def.fetch(:alert)

  begin
    puts 'Trying to create webhook action'
    @alerts_client.create_action 'webhook', "send-via-webhook-#{metric_id}", @webhook_props

  rescue Hawkular::BaseClient::HawkularException => e
    if e.status_code == 409
      puts 'Webhook action already existed'
      @client.delete_action 'webhook', "send-via-webhook-#{metric_id}"
      retry
    end
  end

  # Create the trigger
  t = Hawkular::Alerts::Trigger.new({})
  t.enabled = true
  t.id = "trigger_#{metric_id}"
  t.name = "Trigger on #{name}"
  t.severity = :HIGH
  t.description = "High temp on #{name} (#{metric_id})"
  t.tags = { :resourceId => "#{feed}/#{res_id}" }
  t.type = :MEMBER
  t.context = { :triggerType => :Threshold,
                :alertType => :ABS_VALUE } # Fake, but UI does not accept all values

  # Create a condition
  c = Hawkular::Alerts::Trigger::Condition.new({})
  c.trigger_mode = :FIRING
  c.type = :THRESHOLD
  c.data_id = metric_id
  c.operator = alert[:comparator].to_s.upcase
  c.threshold = alert[:value]

  # Reference an action definition
  a = Hawkular::Alerts::Trigger::Action.new({})
  a.action_plugin = 'webhook'
  a.action_id = "send-via-webhook-#{metric_id}"
  t.actions.push a

  begin
    @alerts_client.delete_trigger t.id
  rescue
    puts 'Trigger did not yet exist'
  end

  begin
    @alerts_client.create_trigger t, [c], nil
    puts 'Trigger created'
  rescue Exception => e
    puts 'Trigger creation failed : ' + e.to_s
  end


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

