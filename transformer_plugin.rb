require 'aggregator_plugin'

module TransformerPlugin
    class Generator
	def generate(task, config)
            port_listener_ext = task.extension("port_listener")

	    config.streams.each do |stream|
		#push data in update hook
		port_listener_ext.add_port_listener(stream.name) do |sample_name|
		    "
	#{config.name}.pushData(#{idx_name(stream)}, #{sample_name}.time, #{sample_name});"
		end
	    end	    
	    
	    task.add_base_header_code("#include<transformer/Transformer.h>", true)
	    #a_transformer to be shure that the transformer is declared BEFORE the Transformations
	    task.add_base_member("a_transformer", config.name, "transformer::Transformer")
	    task.add_base_member("lastStatusTime", "_lastStatusTime", "base::Time")
	    
	    task.in_base_hook("configure", "
    #{config.name}.clear();
    #{config.name}.setTimeout( base::Time::fromSeconds( _transformer_max_latency.value()) );
	    ")	    
	    
	    config.transformations.each do |t|
		task.add_base_member("transformer", member_name(t), "transformer::Transformation &").
		    initializer("#{member_name(t)}(#{config.name}.registerTransformation(\"#{t.from}\", \"#{t.to}\"))")
	    end
	    
	    config.streams.each do |stream|
		stream_data_type = type_cxxname(task, stream)
		
		#add variable for index
		task.add_base_member("transformer", idx_name(stream), "int")
		
		#add callbacks
		task.add_user_method("void", callback_name(stream), "const base::Time &ts, const #{stream_data_type} &#{stream.name}_sample").
		body("    throw std::runtime_error(\"Transformer callback for #{stream.name} not implemented\");")

		#register streams at transformer
		task.in_base_hook("configure", "
    {
    const double #{stream.name}Period = _#{stream.name}_period.value();
    #{idx_name(stream)} = #{config.name}.registerDataStream< #{stream_data_type}>(
		    base::Time::fromSeconds(#{stream.name}Period), boost::bind( &#{task.class_name()}Base::#{callback_name(stream)}, this, _1, _2));
    }


    std::vector<base::samples::RigidBodyState> const& staticTransforms =
        _static_transforms.get();
    for (int i = 0; i < staticTransforms.size(); ++i)
        #{config.name}.pushStaticTransformation(staticTransforms[i]);
		")

		#unregister in cleanup
		task.in_base_hook("cleanup", "
    #{config.name}.unregisterDataStream(#{idx_name(stream)});")
	    end

	    task.in_base_hook("update", "
    base::samples::RigidBodyState dynamicTransform;
    while(_dynamic_transformations.read(dynamicTransform, false) == RTT::NewData) {
	#{config.name}.pushDynamicTransformation(dynamicTransform);
    }

    while(#{config.name}.step()) 
    {
	;
    }")

	    task.in_base_hook('update', "
    {
	const base::Time curTime(base::Time::now());
	if(curTime - _lastStatusTime > base::Time::fromSeconds(1))
	{
	    _lastStatusTime = curTime;
	    _#{config.name}_status.write(#{config.name}.getStatus());
	}
    }")

	    #unregister in cleanup
	    task.in_base_hook("stop", "
    #{config.name}.clear();")
	end

        def member_name(t)
            "_#{t.from}2#{t.to}"
        end

        def idx_name(stream)
            "#{stream.name}_idx_tr"
        end

        def type_cxxname(task, stream)
            port = task.find_port(stream.name)
            if(!port)
                raise "Error trying to register nonexisting port " + name + " to the transformer"
            end
        
            port.type.cxx_name
        end
        
        def callback_name(stream)
            "#{stream.name}TransformerCallback"
        end
    end

    # This class is used to add some information to the task's oroGen
    # specification
    #
    # It gets added when #transformer is called on the task context. It can be
    # retrieved with:
    #
    #   transformer = task_model.transformer
    #
    # Or, more generically
    #
    #   transformer = task_model.extension("transformer")
    #
    class Extension
        # Describes an input stream on the transformer. It behaves like a stream
        # on a stream aligner
	class StreamDescription
	    def initialize(name, period)
		@name   = name
		@period = period
	    end

	    attr_reader :name
	    attr_reader :period
	end
	
        # Describes a transformation
	class TransformationDescription
	    attr_reader :from
	    attr_reader :to
	    
	    def initialize(from, to)
		@from = from
		@to = to
	    end
	end
	
	dsl_attribute :name do |new_name|
            new_name = new_name.to_str
            if new_name !~ /^\w+$/
                raise ArgumentError, "transformer names can only contain alphanumeric characters and _"
            end
            @default_transformer = false
            new_name
        end

        attr_predicate :default?, true

        attr_reader :task

	dsl_attribute :max_latency
	attr_reader :streams
	attr_reader :transformations
        attr_reader :available_frames
        attr_reader :frame_associations

	def initialize(task)
            @task = task

	    @streams = Array.new()
	    @transformations = Array.new()
            @name = "transformer"
            @default = true
            @available_frames = Set.new
            @frame_associations = Hash.new
	end
	
	def align_port(name, period)
	    streams << StreamDescription.new(name, period)
	end

        def has_frame?(frame_name)
            frame_name = frame_name.to_s
            available_frames.include?(frame_name)
        end

        def associate_frame_to_port(frame_name, port_name)
            if !task.has_port?(port_name)
                raise ArgumentError, "task #{task.name} has no port called #{port_name}"
            elsif !has_frame?(frame_name)
                raise ArgumentError, "no frame #{frame_name} is declared"
            end
            frame_associations[port_name] = frame_name
        end

        def find_frame_of_port(port)
            port = if port.respond_to?(:name) then port.name
                   else port
                   end

            @frame_associations[port]
        end

        def frame_of_port(port)
            if result = find_frame_of_port(port)
                return result
            else raise ArgumentError, "#{port} has no associated frame"
            end
        end

        def frames(*frame_names)
            if frame_names.last.kind_of?(Hash)
                port_frames = frame_names.pop
                frame_names = frame_names.to_set | port_frames.keys
            end

            frame_names.each do |name|
                name = name.to_s
                if name !~ /^\w+$/
                    raise ArgumentError, "frame names can only contain alphanumeric characters and _, got #{name}"
                end
                available_frames << name.to_str
            end

            if port_frames
                port_frames.each do |frame_name, port_name|
                    associate_frame_to_port(frame_name, port_name)
                end
            end
        end

	def transformation(from, to)
            if !available_frames.include?(from)
                raise ArgumentError, "#{from} is not a declared frame"
            end
	    transformations.push(TransformationDescription.new(from, to))
	end
	
        def update_spec
	    task.project.using_library('transformer', :typekit => false)

	    task.property("transformer_max_latency", 'double', max_latency).
		doc "Maximum time in seconds the transformer will wait until it starts dropping samples"
	    Orocos::Generation.info("transformer: adding property transformer_max_latency to #{task.name}")

	    task.project.import_types_from('aggregator')

	    #add output port for status information
	    task.output_port("#{self.name}_status", '/aggregator/StreamAlignerStatus')
	    Orocos::Generation.info("transformer: adding port #{name}_status to #{task.name}")
	    
	    #add period property for every data stream
	    streams.each do |stream|
		property_name = "#{stream.name}_period"
		if !task.find_property(property_name)
		    task.property(property_name,   'double', stream.period).
			doc "Time in s between #{stream.name} readings"
		    Orocos::Generation.info("transformer: adding property #{property_name} to #{task.name}")
		end
	    end	    
	    
	    #create ports for transformations
	    task.property('static_transformations', 'std::vector</base/samples/RigidBodyState>').
                doc "list of static transformations"
	    task.input_port('dynamic_transformations', '/base/samples/RigidBodyState').
		needs_reliable_connection
		
	    task.hidden_operation("setFrameMapping", "    #{self.name}.setFrameMapping(sourceFrame, mappedFrame);").
		argument('sourceFrame', '/std/string').
		argument('mappedFrame', '/std/string').
		doc("Maps the local frame name 'sourceFrame' to a global 'mappedFrame'. This method may be called multiple times.")
        end

        def register_for_generation(task)
            Generator.new.generate(task, self)
        end
    end

    def transformer(&block)
        if !block_given?
            return extension("transformer")
        end

	PortListenerPlugin.add_to(self)

	config = TransformerPlugin::Extension.new(self)
	config.instance_eval(&block)
	if !config.max_latency
	   raise "not max_latency specified for transformer" 
	end
	
        config.update_spec
        register_extension("transformer", config)
    end
end


class Orocos::Spec::TaskContext
    include TransformerPlugin
end
