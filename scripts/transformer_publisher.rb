require 'orocos'
require 'transformer/runtime'
require 'pry'

Orocos.initialize
Orocos.transformer.load_conf('transforms.rb')

Orocos.transformer.manager.conf.dynamic_transform "task_a.tr_out","O" => "A"
Orocos.transformer.manager.conf.dynamic_transform "task_b.tr_out","O" => "B"
Orocos.transformer.update_configuration_state

Orocos.run Transformer.broadcaster_name do
    bc=Orocos.name_service.get(Transformer.broadcaster_name)
    bc.start
    sleep(1)
    bc.setConfiguration Orocos.transformer.configuration_state
    STDIN.readline
end
