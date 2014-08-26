#!/usr/bin/env ruby
# == Synopsis
#
# Retrieve cluster of a site and their nodes with the API. 
# Request each node to retrieve switch address and OIDs.
#
# == Usage
#
# ruby configure-driver.rb [ -h | --help ] [ -s site ]
#
# site::
#    The +site+ argument correspond to the site you 
#    want to configure.
#
# == Author
# Clement Parisot, Loria - Algorille, Nancy

require 'pp'
require 'rest_client'
require 'json'
require 'snmp'
require 'resolv'
include SNMP
require 'optparse'

options = {
  site:	nil,
  cluster: "",
  endpoint:	"ipc:///tmp/kwapi-drivers",
  signing:	"true",
  secret:	"G5K Power Measurements Service",
  interval:	"60",
  log_file:	"/var/log/kwapi/kwapi-drivers.log",
  verbose:	"true"
}

$switchs = {}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby #{$0} -s site [options]"
  opts.on("-s", "--site  SITE", "The SITE you want to configure") do |str|
    options[:site] = str
  end
  opts.on("-c", "--cluster CLUSTER", "The CLUSTER you want to configure (OPTIONNAL)") do |str|
    options[:cluster] = str
  end
  opts.on("-e", "--endpoint LOCATION", "Where the probes have to be stocked") do |loc|
    options[:endpoint] = loc
  end
  opts.on("--sign", "--signing {true | false}", "Datas have to be signed") do |sign|
    options[:signing] = sign
  end
  opts.on("--secret", "Secret passphrase") do |pass|
    options[:secret] = pass
  end
  opts.on("-i", "--interval SECONDS", "Interval in seconds") do |sec|
    options[:interval] = sec
  end
  opts.on("-l", "--log-file LOCATION", "Where the logs are registered") do |loc|
    options[:log_file] = loc
  end
  opts.on("-v", "--verbose {true | false}", "Driver verbosity") do |v|
    options[:verbose] = v
  end
end.parse!

#Missing site name
if options[:site].nil?
  puts "Usage: ruby #{$0} -s site [options] (-h for help)"
  raise OptionParser::MissingArgument
end

#Print the header
def header(options)
  puts "# Kwapi drivers config file

[DEFAULT]

# Communication
probes_endpoint = '#{options[:endpoint]}'

# Signature
enable_signing = '#{options[:signing]}'
metering_secret = '#{options[:secret]}'

# Timers
check_drivers_interval = '#{options[:interval]}'

# Log files
log_file = '#{options[:log_file]}'
verbose = '#{options[:verbose]}'

# Network config"
end

#Parse the cluster file to extract nodes uids
def parse_cluster(file, site)
  d = JSON::parse IO::read(file)
  nodes = []
  d['items'].each do |item|
    if item['type'] == "network_equipment"
      switch = item['uid']
      l = -1
      item['linecards'].each do |linecard|
        l+=1
        snmp_pattern = linecard['snmp_pattern']
        if snmp_pattern.nil?
          $stderr.puts "No pattern for #{switch}:#{l}"
        else
          p = -1
          ports = linecard['ports']
          if !ports.nil? 
            ports.each do |port|
              p+=1
              uid = port['uid']
              device_port = port['port'].nil? ? "" : "-#{port['port']}"
              begin
                device = "#{uid.nil? ? "None" : "#{uid}#{device_port}->#{switch}"}"
                switch_port = "#{snmp_pattern.sub("%LINECARD%", l.to_s).sub("%PORT%", p.to_s)}"
                if !uid.nil?
                  $switchs.key?(switch) ? $switchs[switch][switch_port]=device : $switchs[switch]={switch_port=>device}
                end
              rescue
                $stderr.puts "Can't write #{switch}:#{snmp_pattern}:#{l}:#{p}:#{uid} : #{$!}" 
              end
            end
          end
        end
      end
    end
  end
end

#SNMP Requests to find the correct OID
def write_probes(site,switch)
  if switch == "" || switch.nil?
    return
  end
  switch_addr = Resolv.getaddress switch+".#{site}.grid5000.fr"
  probesIN = []
  probesOUT = []
  begin
    SNMP::Manager.open(:host => switch_addr) do |manager|
      manager.walk(["ifDescr"]) do |(ifDescr)|
        node = $switchs[switch][ifDescr.value]
        probesIN << "#{node.nil? ? "None" : "'" + node + "'"}"
        probesOUT << "#{node.nil? ? "None" : "'" + node + "'"}"
      end
    end
  rescue
    return
  end
  #Erase last 'None' values
  probesIN.pop until probesIN[-1] != 'None'
  probesOUT.pop until probesOUT[-1] != 'None'
  if probesIN.length == 0 || probesOUT.length == 0 #no probes on switch
    return
  end
  printf "[%s-IN]\n", switch
  printf "probes = [%s]\n", probesIN.join(",")
  printf "driver = Snmpin\n"
  printf "parameters = {'protocol': '1', 'community': 'public', 'ip': '%s.%s.grid5000.fr', 'oid': '1.3.6.1.2.1.2.2.1.16'}\n", switch, site
  printf "[%s-OUT]\n", switch
  printf "probes = [%s]\n", probesOUT.join(",")
  printf "driver = Snmpout\n"
  printf "parameters = {'protocol': '1', 'community': 'public', 'ip': '%s.%s.grid5000.fr', 'oid': '1.3.6.1.2.1.2.2.1.10'}\n", switch, site
end

# Parsing json and looking for switch.content and swith_port.content
def api_lookup(site,cluster,node)
  #Define default link to the API
  api = RestClient::Resource.new('https://api.grid5000.fr/stable/', :verify_ssl => OpenSSL::SSL::VERIFY_NONE)

  #Get cluster information
  network_equipments = JSON.parse api["sites/#{site}/clusters/#{cluster}/nodes/#{node}"].get(:accept => 'application/json')

  #Parsing the JSON and looking for switch,switch_port
  network_equipments['network_adapters'].each do |(net_content)|
    port = net_content['switch_port']
    switch = net_content['switch']
    device = "#{node}-#{net_content['device']}"
    $switchs.key?(switch) ? $switchs[switch][port]=device : $switchs[switch]={port=>device}
  end
end

header(options)
#Iteration on each cluster of the site
Dir::glob("*#{options[:site]}-network_equipments*").each do |f|
    sitename = f.gsub(/(.*)-.*-.*/, '\1')
    parse_cluster(f, sitename)
end

#walk on $switchs to place node probes later
$switchs.keys.each do |switch|
  write_probes(options[:site], switch)
end

