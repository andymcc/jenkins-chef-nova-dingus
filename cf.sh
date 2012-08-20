#!/bin/bash

INSTANCE_IMAGE=bridge-precise

source $(dirname $0)/chef-jenkins.sh
source $(dirname $0)/files/cloudfiles-credentials

init

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x

declare -a cluster
cluster=(mysql keystone glance api horizon compute1 compute2 graphite)

boot_and_wait chef-server
wait_for_ssh $(ip_for_host chef-server)

x_with_server "Uploading cookbooks" "chef-server" <<EOF
apt-get update
flush_iptables
install_package git-core
rabbitmq_fixup
chef_fixup
checkout_cookbooks
upload_cookbooks
upload_roles
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
wait_for_cluster_ssh ${cluster[@]}

echo "Cluster booted... setting up vpn thing"
setup_private_network br100 br99 api ${cluster[@]}

# at this point, chef server is done, cluster is up.
# let's set up the environment.

create_chef_environment chef-server cloudfiles
set_environment_attribute chef-server cloudfiles "override_attributes/glance/image_upload" "false"

# set environment to use swift/cloudfiles for image storage
set_environment_attribute chef-server cloudfiles "override_attributes/glance/api/default_store" "\"swift\""
set_environment_attribute chef-server cloudfiles "override_attributes/glance/api/swift_store_user" "\"${ST_USER}\""
set_environment_attribute chef-server cloudfiles "override_attributes/glance/api/swift_store_key" "\"${ST_KEY}\""
set_environment_attribute chef-server cloudfiles "override_attributes/glance/api/swift_store_version" "\"${ST_AUTH_VERSION}\""
set_environment_attribute chef-server cloudfiles "override_attributes/glance/api/swift_store_address" "\"${ST_AUTH}\""


x_with_cluster "Running/registering chef-client" ${cluster[@]} <<EOF
apt-get update
flush_iptables
install_chef_client
fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client -ldebug
EOF

# clients are all kicked and inserted into chef server.  Need to
# set up the proper roles for the nodes and go.
for d in "${cluster[@]}"; do
    set_environment chef-server ${d} cloudfiles
done

role_add chef-server mysql "role[mysql-master]"
x_with_cluster "Installing mysql" mysql <<EOF
chef-client -ldebug
EOF

role_add chef-server keystone "role[rabbitmq-server]"
role_add chef-server keystone "role[keystone]"
x_with_cluster "Installing keystone" keystone <<EOF
chef-client -ldebug
EOF

role_add chef-server glance "role[glance-registry]"
role_add chef-server glance "role[glance-api]"

x_with_cluster "Installing glance" glance <<EOF
chef-client -ldebug
EOF

role_add chef-server api "role[nova-setup]"
role_add chef-server api "role[nova-scheduler]"
role_add chef-server api "role[nova-api-ec2]"
role_add chef-server api "role[nova-api-os-compute]"
role_add chef-server api "role[nova-vncproxy]"
role_add chef-server api "role[nova-volume]"

x_with_cluster "Installing nova infra/API" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

role_add chef-server api "recipe[kong]"
role_add chef-server api "recipe[exerstack]"
role_add chef-server horizon "role[horizon-server]"
role_add chef-server compute1 "role[single-compute]"
role_add chef-server compute2 "role[single-compute]"

# turn on glance uploads again
set_environment_attribute chef-server cloudfiles "override_attributes/glance/image_upload" "true"

# and again, just for good measure.
x_with_cluster "All nodes - Pass 2" ${cluster[@]} <<EOF
chef-client -ldebug
EOF

x_with_server "fixerating" api <<EOF
ip addr add 192.168.100.254/24 dev br99
EOF
background_task "fc_do"
collect_tasks

retval=0

if ( ! run_tests api essex-final nova glance keystone glance-swift ); then
    echo "Tests failed."
    retval=1
fi

x_with_cluster "Fixing log perms" keystone glance api horizon compute1 compute2  <<EOF
if [ -e /var/log/nova ]; then chmod 755 /var/log/nova; fi
if [ -e /var/log/keystone ]; then chmod 755 /var/log/keystone; fi
if [ -e /var/log/apache2 ]; then chmod 755 /var/log/apache2; fi
EOF

cluster_fetch_file "/var/log/{nova,glance,keystone,apache2}/*log" ./logs ${cluster[@]}

if [ $retval -eq 0 ]; then
    github_post_comment ${GIT_COMMENT_URL} "Gate:  Nova AIO\n * ${BUILD_URL}consoleFull : SUCCESS"
fi

exit $retval
