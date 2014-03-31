require 'orocos'
Orocos.initialize
Orocos.load_typekit('base')

task = Orocos::RubyTaskContext.new "task_b"
p=task.create_output_port('tr_out', Types::Base::Samples::RigidBodyState)
task.configure
task.start
while true
    sample = Types::Base::Samples::RigidBodyState.new
    sample.position = Types::Base::Vector3d.new(0,3,1)
    sample.orientation = Types::Base::Quaterniond.from_angle_axis(0.2,Types::Base::Vector3d.new(1,0,0))
    sample.sourceFrame = "O"
    sample.targetFrame = "B"
    sample.time=Types::Base::Time.now
    
    p.write(sample)
    sleep(0.1)
end

task.stop
task.dispose
