
module TransformerPlugin
    include AggregatorPlugin
    
    class TransformerGenerator
	attr_accessor :task
	attr_reader :transformer_name
	
	def initialize(task)
	    @task = task
	    @transformer_name = "transformer"
	end

	def generate_parse_time_code(config)

	    task.property("transformer_timeout",   'double', config.timeout).
		doc "Maximum time that should be waited for a delayed data sample to arrive"
	    puts("Adding property transformer_timeout")

	    #add period property for every data stream
	    config.streams.each do |m|
		property_name = "#{m.name}_period"
		if(!(task.find_property(property_name)))
		    task.property(property_name,   'double', m.period).
			doc "Time in s between #{m.name} readings"
		    puts("Adding property #{property_name}")
		end
		
		#push data in update hook
		task.add_port_listener(m.name) do |sample_name|
		    "
	#{transformer_name}.pushData(#{m.idx_name}, #{sample_name}.time, #{sample_name});"
		end
	    end
	    
	    #create ports for transformations
	    #TODO what type ? /std/vector</wrappers/samples/RigidBodyState>
	    task.input_port('static_transformations', '/std/vector</base/samples/RigidBodyState>')
	    task.input_port('dynamic_transformations', '/base/samples/RigidBodyState').
		needs_reliable_connection
	    
	end
	def generate_transformer_code(config)
	    task.add_base_header_code("#include<transformer/Transformer.h>", true)
	    task.add_base_member("transformer", transformer_name, "transformer::Transformer")

	    task.in_base_hook("configure", "
    #{transformer_name}.setTimeout( base::Time::fromSeconds( _transformer_timeout.value()) );
	    ")	    
		
	    config.streams.each do |s|
		stream_data_type = s.get_data_type(task)
		
		#add variable for index
		task.add_base_member("transformer", s.idx_name, "int")
		
		#add callbacks
		task.add_user_method("void", s.callback_name, "const base::Time &ts, const #{stream_data_type} &#{s.name}_sample, const transformer::Transformation &#{s.source_frame}2#{s.target_frame}").
		body("    throw std::runtime_error(\"Transformer callback for #{s.name} not implemented\");")

		#register streams at transformer
		buffer_size_factor = 2.0
		task.in_base_hook("configure", "
    {
    const double #{s.name}Period = _#{s.name}_period.value();
    #{s.idx_name} = #{transformer_name}.registerDataStreamWithTransform< #{stream_data_type}>(
		    base::Time::fromSeconds(#{s.name}Period), std::string(\"#{s.source_frame}\"), std::string(\"#{s.target_frame}\"),
		    boost::bind( &TaskBase::#{s.callback_name}, this, _1, _2, _3 ),
		    #{s.interpolate});
    }
		")
		
		task.in_base_hook("update", "
    std::vector<base::samples::RigidBodyState> staticTransforms;
    while(_static_transformations.read(staticTransforms) == RTT::NewData) {
	for(std::vector<base::samples::RigidBodyState>::const_iterator it = staticTransforms.begin(); it != staticTransforms.end(); it++)
	{
	    #{transformer_name}.pushStaticTransformation(*it);
	}
    }
		                 
    base::samples::RigidBodyState dynamicTransform;
    while(_dynamic_transformations.read(dynamicTransform) == RTT::NewData) {
	#{transformer_name}.pushDynamicTransformation(dynamicTransform);
    }    
		                  
    while(#{transformer_name}.step()) 
    {
	;
    }")
	    end
	end
    end
    
    class TransformerConfiguration
	class StreamDescription
	    def initialize(name, period, source_frame, target_frame, interpolate)
		@name = name
		@period = period
		@source_frame = source_frame
		@target_frame = target_frame
		@idx_name = name + "_idx_tr"
		@callback_name = name + "TransformerCallback"
		@interpolate = interpolate;
	    end
	    attr_reader :name
	    attr_reader :period
	    attr_reader :source_frame
	    attr_reader :target_frame
	    attr_reader :idx_name
	    attr_reader :callback_name
	    attr_reader :interpolate
	    
	    def get_data_type(task)
		port = task.find_port(name)
		if(!port)
		    raise "Error trying to register nonexisting port " + name + " to the transformer"
		end
	    
		port.type.cxx_name	    
	    end

	end
	
	dsl_attribute :timeout
	attr_accessor :streams

	def add_port()
	end
	
	def initialize()
	    @streams = Array.new()
	end
	
	def align_port_with_transformation(name, period, sourceFrame, targetFrame, interpolate = false)
	    streams << StreamDescription.new(name, period, sourceFrame, targetFrame, interpolate)
	end

    end
    
    def add_transformer(&block)
	register_port_listener_generator()

	config = TransformerConfiguration.new()
	config.instance_eval(&block)

	if(!config.timeout)
	   raise "not timeout specified for transformer" 
	end
	
	gen = TransformerGenerator.new(self)
	gen.generate_parse_time_code(config)
	
	#register code generator to be called after parsing is done
	add_generation_handler do
	    puts("test")
	    gen.generate_transformer_code(config)
	end

    end
end


class Orocos::Generation::TaskContext
    include TransformerPlugin
end