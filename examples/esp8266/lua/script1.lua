-- sample code to run on an ESP8266
-- like the Adafruit Huzzah ESP
-- with a 1 wire ds1820 on Huzzah pin 12
-- which maps to ESP port 6
-- this script contains code found on the
-- NodeMCU readthedocs page

-- The Huzzah needs a firmware with
-- net, mqtt, wifi, onewire

--  change the following to match your setup
pin = 6 -- data pin of the DS1820 (ESP pin)
SSID = "CHANGEME"     -- Wifi SSID
PASSWORD = "CHANGEME" -- WIfi Password
BROKER = "1.2.3.4"    -- IP of your MQTT broker
--


metric_topic = "/hawkular/metrics"
register_topic = "/hawkular/register"
addr = nil
mq = nil

-- start up wifi and request an address from the DHCP server
function wifi_start()
    if (wifi.sta.status() ~= 5)
    then
        print( wifi.sta.status())
        wifi.setmode(wifi.STATION)
        wifi.sta.config(SSID,PASSWORD)
        wifi.sta.connect()
        tmr.delay(1000000)   -- wait 1,000,000 us = 1 second
        local status
        local count = 0
        repeat
          count = count +1
          status = wifi.sta.status()
          tmr.delay(10000) -- wait 100ms per round
        until (status == 5) or (count > 100)
    end
end

-- Format the onewire address
function format_ow_addr(addr)
    local res = ""
    for i=1,8 do
      res = res..addr:byte(i)
      if i < 8 then
         res = res.."."
      end
    end
    return res
end

-- set up the OneWire bus and search for sensor(s)
function ow_setup()
    ow.setup(pin)
    local count = 0
    repeat
        count = count + 1
        addr = ow.reset_search(pin)
        addr = ow.search(pin)
        tmr.wdclr()
    until (addr ~= nil) or (count > 100)

    if addr == nil then
        print("No more addresses.")
    else
        print(format_ow_addr(addr))
        local crc = ow.crc8(string.sub(addr,1,7))
        if crc == addr:byte(8) then
            if (addr:byte(1) == 0x10) or (addr:byte(1) == 0x28) then
                print("Device is a DS18S20 family device.")
            else
                print("Device family is not recognized.")
            end
        else
            print("CRC is not valid!")
        end
    end
end

-- read the temperature from the (only) sensor
function get_temp()
  ow.reset(pin)
  ow.select(pin, addr)
  ow.write(pin, 0x44, 1)
  tmr.delay(1000000)
  local present = ow.reset(pin)
  ow.select(pin, addr)
  ow.write(pin,0xBE,1)
  print("P="..present)
  tmr.delay(100000)
  local data
  data = string.char(ow.read(pin))
  for i = 1, 8 do
    data = data .. string.char(ow.read(pin))
  end
  print(data:byte(1,9))
  local crc = ow.crc8(string.sub(data,1,8))
  print("CRC="..crc)
  if crc == data:byte(9) then
     local t = (data:byte(1) + data:byte(2) * 256) * 625
     local t1 = t / 10000
     local t2 = t % 10000
     print("Temperature="..t1.."."..t2.."Centigrade")
     return ""..t1.."."..t2
  else
     print("Bad crc")
     return "-40.0"
  end

end

-- Start mqtt communications
function mqtt_start()
    tmr.stop(6)

    mq = mqtt.Client(node.chipid(),120)

    mq:on("connect", function(client)
        print ("connected")
        register()
    end)

    mq:on("offline", function(client)
        print ("offline")
    end)

    mq:connect(BROKER,1883,0, true, function(con)
        print("-> Connected")
    end
    )

    tmr.alarm(6, 60000, 1, send_temperature)

end

-- register with Hawkular
function register()

    local tab = { feed = node.chipid(),
            rt = "esp8266",
            r = "mcu"..node.chipid(),
            mt = {
                id = "thermo",
            },
            m = {
                mt = "thermo",
                id = getMetricName()
            }
    }

    local message = cjson.encode(tab)
    print("Registering as " .. message)
    mq:publish(register_topic, message, 1,0, function(pub)
        print("-> sent registration")
    end)

end

-- Obtain the name of the metric
function getMetricName()
    return node.chipid() .. ":" .. format_ow_addr(addr)
end

-- send the temperature to the broker
function send_temperature()
    print("ping")
    local temp = get_temp(pin,addr)
    local message  =  getMetricName() .." "..temp

    mq:publish(metric_topic, message, 1, 0, function(pub)
        print("temp sent")
    end)

end


-- show starts here
wifi_start()
ow_setup()
mqtt_start()

