# Building a VHD image using Azure.
require 'azure'
require 'sshkit'
require 'sshkit/dsl'
require 'rest-client'
require 'securerandom'

Azure.management_certificate = "/home/joel/azureJcarmstr.pem"
Azure.subscription_id = "2e588d56-6c30-4b5e-8527-4260216a11b1"

$vmm = Azure.vm_management

SSHKit::Backend::Netssh.configure do |ssh|
  ssh.ssh_options = {
    keys: %w(/home/joel/azureSSH.key)
  }
end

def provision(region, image_name, name, cloud_service, user='toilprovisioning',
              block_until_ready=true)
  vm = $vmm.create_virtual_machine({:vm_name => name,
                                    :vm_user => user,
                                    :image => image_name,
                                    :location => region},
                                   {:storage_account_name => cloud_service,
                                    :cloud_service_name => cloud_service,
                                    :deployment_name => name,
                                    :private_key_file => '/home/joel/azureSSH.key',
                                    :ssh_port => 22,
                                    :vm_size => 'Small'})
  if block_until_ready
    while $vmm.get_virtual_machine(name, 'toilprovisioning').status != "ReadyRole"
      puts "waiting to come up..."
      sleep 30
    end
  end
  return "#{user}@#{vm.ipaddress}"
end

def stop(server, cloud_service)
  $vmm.shutdown_virtual_machine(server, cloud_service)
end

def delete(server, cloud_service)
  $vmm.delete_virtual_machine(server, cloud_service)
end

def capture_image(name, cloud_service, target_name, block_until_ready=true)
  endpoint = RestClient::Resource.new(
    "https://management.core.windows.net/#{Azure.subscription_id}/services/hostedservices/#{cloud_service}/deployments/#{name}/roleinstances/#{name}/Operations",
    :ssl_client_cert => OpenSSL::X509::Certificate.new(File.read("/home/joel/azureJcarmstr.pem")),
    :ssl_client_key => OpenSSL::PKey::RSA.new(File.read("/home/joel/azureJcarmstr.pem")),
    :verify_ssl => OpenSSL::SSL::VERIFY_NONE)
  payload = <<END
<CaptureRoleOperation xmlns="http://schemas.microsoft.com/windowsazure" xmlns:i="http://www.w3.org/2001/XMLSchema-instance">
  <OperationType>CaptureRoleOperation</OperationType>
  <PostCaptureAction>Delete</PostCaptureAction>
  <TargetImageLabel>#{target_name}</TargetImageLabel>
  <TargetImageName>#{target_name}</TargetImageName>
</CaptureRoleOperation>
END
  endpoint.post(payload, {"content-type" => "application/xml",
                          "x-ms-version" => "2015-04-01"})
  if block_until_ready
    while Azure.vm_image_management.list_os_images
           .select { |i| i.name == target_name }
           .length == 0
      puts 'waiting for image to be ready...'
      sleep 30
    end
  end
end

def from(image_name, &block)
  cloud_service = 'toilprovisioning'
  name = SecureRandom.hex
  server = provision("West US", image_name, name, cloud_service, 'provisioner')
  begin
    on(server, &block)
    on(server) do
      as 'root' do
        execute(:waagent, "-deprovision+user", "-force")
      end
    end
    stop(name, cloud_service)
    capture_image(name, cloud_service, name)
  rescue
    delete(name, cloud_service)
  end
  return name
end

image1 = from("b39f27a8b8c64d52b05eac6a62ebad85__Ubuntu-14_04_3-LTS-amd64-server-20150805-en-us-30GB") do
  puts capture(:whoami)
  as 'root' do
    execute(:'apt-get', 'update')
    execute(:'apt-get', 'install', 'cowsay')
  end
end

image2 = from(image1) do
  puts capture(:cowsay, 'moo')
end

puts image2
