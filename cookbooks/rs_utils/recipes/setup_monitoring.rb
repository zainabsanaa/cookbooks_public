# Cookbook Name:: rs_utils
# Recipe:: setup_monitoring
#
# Copyright (c) 2011 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

log 'Setup RightScale monitoring.'
if !node.has_key? :rightscale
  log 'Not attached to RightScale, skipping monitoring setup.'
  return
end

# patch collectd init script, so it uses collectdmon.  
# only needed for CentOS, Ubuntu already does this out of the box.
cookbook_file "/etc/init.d/collectd" do
  source "collectd-init-centos-with-monitor"
  mode 0755
  only_if "which collectdmon > /dev/null 2>&1"   # only when collectdmon is found installed
  action :nothing
end

# install collectd (with_disabled_epel if required for redhat/centos)
package "collectd" do
  only_if "yum repolist | grep epel > /dev/null 2>&1"
  options "--disablerepo=epel --disablerepo=rightscale-epel"
  notifies :create, resources(:cookbook_file => "/etc/init.d/collectd")
end unless ! node['platform'] =~ /redhat|centos/

package "collectd" do
  not_if "yum repolist | grep epel > /dev/null 2>&1"
end unless node['platform'] =~ /redhat|centos/

# lock this collectd package so it can't be updated (yum on redhat/centos only)
if node['platform'] =~ /redhat|centos/
  bash "yum_exclude_package_collectd" do
    flags "-ex"
    only_if { `file #{lockfile} && grep -c 'exclude=collectd' /etc/yum.repos.d/Epel.repo`.strip == "0" }
    code <<-EOF
      lockfile=/etc/yum.repos.d/Epel.repo
      echo -e "\n# Do not allow collectd version to be modified.\nexclude=collectd\n" >> #{lockfile}
    EOF
  end
end

service "collectd" do
  action :enable  # ensure the service is enabled
end

# add rrd library for ubuntu
package "librrd4" if platform?('ubuntu')

arch = (node[:kernel][:machine] == "x86_64") ? "64" : "i386"
type = (node[:platform] == 'ubuntu') ? "deb" : "rpm"
installed_ver = (node[:platform] == "centos") ? `rpm -q --queryformat %{VERSION} collectd`.strip : `dpkg-query --showformat='${Version}' -W collectd`.strip 
installed = (installed_ver == "") ? false : true
log 'Collectd package not installed' unless installed
log "Checking installed collectd version: installed #{installed_ver}" if installed

# collectd main configuration file
template node['rs_utils']['collectd_config'] do
  backup 5
  source "collectd.config.erb"
  notifies :restart, resources(:service => "collectd"), :delayed
  variables(
    :sketchy_hostname => node['rightscale']['servers']['sketchy']['hostname'],
    :plugins => node.rs_utils.plugin_list_ary,
    :instance_uuid => node['rightscale']['instance_uuid'],
    :collectd_include_dir => node['rs_utils']['collectd_plugin_dir']
  )
end

# == Create plugin conf dir
directory "#{node['rs_utils']['collectd_plugin_dir']}" do
  owner "root"
  group "root"
  recursive true
  action :create
end

# == Install a Nightly Crontask to Restart Collectd 
# Add the task to /etc/crontab, at 04:00 localtime.
cron "collectd" do
  command "service collectd restart > /dev/null"
  minute "00"
  hour   "4"
end

# == Monitor Processes from Script Input 
# Write the process file into the include directory from template.
template File.join(node['rs_utils']['collectd_plugin_dir'], 'processes.conf') do
  backup false
  source "processes.conf.erb"
  notifies :restart, resources(:service => "collectd"), :delayed
  variables(
    :monitor_procs => node.rs_utils.process_list_ary,
    :procs_match => node['rs_utils.process_match_list']
  )
end

# set rs monitoring tag to active
right_link_tag "rs_monitoring:state=active" 

log "RightScale monitoring setup complete."