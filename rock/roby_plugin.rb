require 'transformer'

module Transformer
    # Exception raised when two different frames are being selected on the same task-local frame
    class FrameMismatch < RuntimeError; end

    # Module used to extend the device specification objects with the ability
    # to specify frames
    #
    # The #frame attribute allows to specify in which frame this device
    # produces information.
    module DeviceExtension
        ## 
        # Declares the frame in which this device produces data
        dsl_attribute :frame do |value|
            value.to_str
        end

        ## 
        # Declares the frame transformation in which this device produces
        # transformations
        dsl_attribute :frame_transform do |value|
            if value.kind_of?(Transform)
                value
            else
                if !value.kind_of?(Hash)
                    raise ArgumentError, "expected a from => to mapping, got #{value}"
                elsif value.size > 1
                    raise ArgumentError, "more than one transformation provided"
                end
                Transform.new(*value.to_a.first)
            end
        end
    end

    # Module used to extend the instance specification objects with the ability
    # to map frame names to global frame names
    #
    # A frame mapping applies recursively on all levels of the hierarchy. I.e.
    # it applies on the particular instance and on all its children.
    module InstanceRequirementsExtension
        # The set of frame mappings defined on this specification
        attribute(:frame_mappings) { Hash.new }

        # Declare frame mappings
        #
        # For instance, doing
        #
        #   use_frames("world" => "odometry")
        #
        # will assign the "odometry" global frame to every task frame called "world".
        def use_frames(frame_mappings)
            self.frame_mappings.merge!(frame_mappings)
            self
        end

        # Updates the frame mappings when merging two instance requirements
        def merge(other_spec)
            super if defined? super

            result = frame_mappings.merge!(other_spec.frame_mappings) do |frame_name, sel0, sel1|
                if !sel0 then sel1
                elsif !sel1 then sel0
                elsif sel0 != sel1
                    raise ArgumentError, "cannot merge #{self} and #{other_spec}: frame mapping for #{frame_name} differ (resp. #{sel0.inspect} and #{sel1.inspect})"
                else
                    sel0
                end
            end
        end

        # Displays the frame mappings when pretty-print an InstanceRequirements
        # object
        #
        # Unlike "normal" pretty-printing, one must always start with a
        # pp.breakable
        def pretty_print(pp)
            super if defined? super

            pp.breakable
            pp.text "Frame Selection:"
            if !frame_mappings.empty?
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(frame_mappings) do |mapping|
                        pp.text "#{mapping.first} => #{mapping.last}"
                    end
                end
            end
        end
    end

    # Module used to extend objects of the class Orocos::RobyPlugin::TaskContext
    module ComponentExtension
        attribute(:selected_frames) { Hash.new }

        # Selects +selected_frame+ for the task's +frame_name+
        #
        # @throws FrameMismatch if a different frame was already selected
        def select_frame(frame_name, selected_frame)
            if current = selected_frames[frame_name]
                if current != selected_frame
                    raise FrameMismatch, "cannot select both #{current} and #{selected_frame} for the frame #{frame_name} of #{self}"
                end
            else
                selected_frames[frame_name] = selected_frame
            end
        end

        # Selects a set of frame mappings
        #
        # See #select_frame
        def select_frames(mappings)
            mappings.each do |name, selected_frame|
                select_frame(name, selected_frame)
            end
        end
    end

    # Module that extends the TaskContext class itself
    module TaskContextExtension
        # Adds a test to the can_merge? predicate to avoid merging two tasks
        # that have different frame mappings
        def can_merge?(merged_task)
            if !(merge_result = super)
                return merge_result
            end

            if tr = self.model.transformer
                tr.available_frames.each do |frame_name|
                    if sel = selected_frames[frame_name]
                        if merged_task.selected_frames[frame_name] != sel
                            return false
                        end
                    end
                end
            end
            return true
        end

        # Adds a pass in the merge operation that updates the selected frames
        # mapping with the mappings stored in the merged task
        def merge(merged_task)
            selected_frames.merge!(merged_task.selected_frames) do |k, v1, v2|
                if v1 != v2
                    raise FrameMismatch, "cannot merge #{merged_task} into #{self} as different frames are selected for #{k}: resp. #{v1} and #{v2}"
                end
                v1
            end
            super if defined? super
        end

        module ClassExtension
            # Allows access to the transformer declaration from the Roby task model
            #
            # It can also be used to define transformer specifications on tasks
            # that don't have one (for instance to tie ports to frames)
            def transformer(*args, &block); orogen_spec.transformer(*args, &block) end
        end
    end

    # Module used to add the 'transforms' annotations to the graph output
    module GraphvizExtension
        def frame_transform_id(task, from, to, prefix= "")
            "frames_#{prefix}#{from}_#{to}_producer"
        end

        def add_frame_transform(task, from, to, prefix = "")
            producer = frame_transform_id(task, from, to, prefix)
            add_vertex(task, producer, "label=\"\",shape=circle")
            add_edge(["frames_#{prefix}#{from}", task], [producer, task], "dir=none")
            add_edge([producer, task], ["frames_#{prefix}#{to}", task], "")
            producer
        end

        def add_transforms_annotations
            plan.find_local_tasks(Orocos::RobyPlugin::TaskContext).each do |task|
                tr = task.model.transformer
                if task.kind_of?(Orocos::RobyPlugin::Device)
                    task.each_device do |srv, dev|
                        selected_frame = dev.frame
                        selected_transform = dev.frame_transform
                        next if !selected_frame && !selected_transform

                        if selected_frame
                            frame_id = "frames_#{dev.name}"
                            add_vertex(task, frame_id, "label=\"dev(#{dev.name})=#{selected_frame}\",shape=ellipse")
                        end
                        if selected_transform
                            from, to = selected_transform.from, selected_transform.to
                            add_vertex(task, "frames_dev_#{dev.name}#{from}", "label=\"dev(#{dev.name}).from=#{from}\",shape=ellipse#{",color=red" if !from}")
                            add_vertex(task, "frames_dev_#{dev.name}#{to}", "label=\"dev(#{dev.name}).to=#{to}\",shape=ellipse#{",color=red" if !from}")
                            transform_id = add_frame_transform(task, from, to, "dev_#{dev.name}")
                        end

                        # Two cases:
                        #  - the device is using the transformer (has frame
                        #    definitions) and declared a link between the frame
                        #    and the output port. This is handled later.
                        #  - the device is NOT using the transformer. Add the
                        #    vertex and edge now
                        srv.each_output_port(true) do |out_port|
                            next if tr && tr.find_frame_of_port(out_port)

                            if transform_id && Transformer.transform_port?(out_port)
                                add_edge([transform_id, task], [out_port, task], "dir=none")
                            elsif frame_id
                                add_edge([frame_id, task], [out_port, task], "dir=none")
                            end
                        end
                    end
                end

                if tr
                    edges = Set.new
                    tr.each_frame do |frame|
                        color = if !task.selected_frames[frame]
                                    ",color=red"
                                end
                        add_vertex(task, "frames_#{frame}", "label=\"#{frame}=#{task.selected_frames[frame]}\",shape=ellipse#{color}")
                        add_edge(["inputs", task], ["frames_#{frame}", task], "style=invis")
                        add_edge(["frames_#{frame}", task], ["outputs", task], "style=invis")
                    end
                    tr.each_transformation do |trsf|
                        add_vertex(task, "frames_#{trsf.from}_#{trsf.to}_producer", "label=\"\",shape=circle")
                        add_edge(["frames_#{trsf.from}", task], ["frames_#{trsf.from}_#{trsf.to}_producer", task], "dir=none")
                        add_edge(["frames_#{trsf.from}_#{trsf.to}_producer", task], ["frames_#{trsf.to}", task], "")
                    end
                    tr.each_transform_port do |port, trsf|
                        add_edge([port, task], ["frames_#{trsf.from}_#{trsf.to}_producer", task], "dir=none,constraint=false")
                    end
                    tr.each_annotated_port do |port, annotated_frame_name|
                        add_edge([port, task], ["frames_#{annotated_frame_name}", task], "dir=none,constraint=false")
                    end
                end
            end
        end
    end

    # Implementation of an algorithm that propagates the frame information along
    # the dataflow network, and makes sure that frame selections are consistent.
    class FramePropagation < Orocos::RobyPlugin::DataFlowComputation
        class FrameAnnotation
            attr_reader :task
            attr_reader :frame_name
            attr_reader :selected_frame

            def initialize(task, frame_name, selected_frame)
                @task, @frame_name, @selected_frame = task, frame_name, selected_frame
            end

            def empty?; !@selected_frame end
            def merge(ann)
                if !ann.kind_of?(FrameAnnotation)
                    raise ArgumentError, "cannot merge a frame annotation with a transform annotation. You are probably connecting two ports, one declared as a transform input or output and one only associated with a frame"
                end

                if ann.name != name
                    raise FrameMismatch, "invalid network: frame #{frame_name} in #{task} would need to select both #{ann.selected_frame} and #{selected_frame}"
                end
            end

            def to_s
                "#<FrameAnnotation: #{task} #{frame_name}=#{selected_frame}>"
            end
        end

        class TransformAnnotation
            attr_reader :task
            attr_reader :from
            attr_reader :to

            def initialize(task, from, to)
                @task = task
                @from = from
                @to   = to
            end

            def empty?; !@from && !@to end
            def merge(ann)
                if !ann.kind_of?(TransformAnnotation)
                    raise ArgumentError, "cannot merge a frame annotation with a transform annotation. You are probably connecting two ports, one declared as a transform input or output and one only associated with a frame"
                end

                @from ||= ann.from
                @to   ||= ann.to
                if ann.from && ann.from != from
                    raise FrameMismatch, "incompatible selection: #{ann.from} != #{@from}"
                end
                if ann.to && ann.to != to
                    raise FrameMismatch, "incompatible selection: #{ann.to} != #{@to}"
                end
            end

            def to_s
                "#<TransformAnnotation: #{task} #{from} => #{to}>"
            end
        end

        def self.compute_frames(plan)
            algorithm = FramePropagation.new
            tasks = plan.find_tasks(Orocos::RobyPlugin::TaskContext).to_value_set
            algorithm.propagate(tasks)
        end

        def required_information(tasks)
            result = Hash.new
            tasks.each do |t|
                next if !(tr = t.model.transformer)

                task_info = [nil]
                tr.each_annotated_port do |port, frame|
                    task_info << port
                end
                result[t] = task_info
            end
            result
        end

        Trigger = Orocos::RobyPlugin::DataFlowComputation::Trigger

        def triggering_port_connections(task)
            return if !(tr = task.model.transformer)

            interesting_ports = Set.new

            result = Hash.new
            connections = Set.new

            tr.each_annotated_port do |port, frame|
                interesting_ports << port.name
            end
            tr.each_transform_port do |port, transform|
                interesting_ports << port.name
            end

            interesting_ports.each do |port_name|
                task.each_concrete_input_connection(port_name) do |source_task, source_port, _|
                    connections << [source_task, source_port]
                end
                task.each_concrete_output_connection(port_name) do |_, sink_port, sink_task, _|
                    connections << [sink_task, sink_port]
                end

                if !connections.empty?
                    result[port_name] = Trigger.new(connections, Trigger::USE_PARTIAL)
                    connections = Set.new
                end
            end
            result
        end

        def initial_information(task)
            tr = task.model.transformer

            # Add frame information from the devices if there is some
            # This does not require the presence of a transformer spec
            if task.kind_of?(Orocos::RobyPlugin::Device)
                task.each_device do |srv, dev|
                    selected_frame = dev.frame
                    selected_transform = dev.frame_transform

                    # Two cases:
                    #  - the device is using the transformer (has frame
                    #    definitions). Assign the selected frame
                    #  - the device is NOT using the transformer. Therefore,
                    #    we must only add the relevant port info
                    srv.each_output_port(true) do |out_port|
                        # Do not associate the ports that output transformations
                        if selected_transform && Transformer.transform_port?(out_port)
                            from, to = selected_transform.from, selected_transform.to
                            if tr && (transform = tr.find_transform_of_port(out_port))
                                if from
                                    task.select_frame(transform.from, from)
                                end
                                if to
                                    task.select_frame(transform.to, to)
                                end
                            else
                                add_port_info(task, out_port.name,
                                    TransformAnnotation.new(task, from, to))
                                done_port_info(task, out_port.name)
                            end
                        elsif selected_frame
                            if tr && (frame_name = tr.find_frame_of_port(out_port))
                                task.select_frame(frame_name, selected_frame)
                            else
                                add_port_info(task, out_port.name,
                                    FrameAnnotation.new(task, frame_name, selected_frame))
                                done_port_info(task, out_port.name)
                            end
                        end
                    end
                end
            end

            # Now look for transformer-specific information
            return if !tr

            # Now add information for all ports for which we know the frame
            # already
            tr.each_annotated_port do |port, frame_name|
                if selected_frame = task.selected_frames[frame_name]
                    add_port_info(task, port.name, FrameAnnotation.new(task, frame_name, selected_frame))
                    done_port_info(task, port.name)
                end
            end
            tr.each_transform_output do |port, transform|
                from = task.selected_frames[transform.from]
                to   = task.selected_frames[transform.to]
                add_port_info(task, port.name, TransformAnnotation.new(task, from, to))
                if from && to
                    done_port_info(task, port.name)
                end
            end
            tr.each_transform_input do |port, transform|
                from = task.selected_frames[transform.from]
                to   = task.selected_frames[transform.to]
                add_port_info(task, port.name, TransformAnnotation.new(task, from, to))
                if from && to
                    done_port_info(task, port.name)
                end
            end

            Transformer.debug do
                Transformer.debug "initially selected frames for #{task}"
                available_frames = task.model.transformer.available_frames.dup
                task.selected_frames.each do |frame_name, selected_frame|
                    Transformer.debug "  selected #{frame_name} for #{selected_frame}"
                    available_frames.delete(frame_name)
                end
                Transformer.debug "  #{available_frames.size} frames left to pick: #{available_frames.to_a.sort.join(", ")}"
                break
            end
        end

        def propagate_task(task)
            return if !(tr = task.model.transformer)

            # First, save the port annotations into the select_frames hash on
            # the task.
            tr.each_annotated_port do |port, frame|
                if has_information_for_port?(task, port.name)
                    task.select_frame(frame, port_info(task, port.name).selected_frame)
                end
            end
            tr.each_transform_port do |port, transform|
                next if !has_information_for_port?(task, port.name)
                info = port_info(task, port.name)

                if info.from
                    task.select_frame(transform.from, info.from)
                end
                if info.to
                    task.select_frame(transform.to, info.to)
                end
            end

            # Then propagate newly found information to ports that are
            # associated with the frames
            has_all = true
            tr.each_annotated_port do |port, frame_name|
                next if has_final_information_for_port?(task, port.name)

                if selected_frame = task.selected_frames[frame_name]
                    if !has_information_for_port?(task, port.name)
                        add_port_info(task, port.name, FrameAnnotation.new(task, frame_name, selected_frame))
                        done_port_info(task, port.name)
                    end
                else
                    has_all = false
                end
            end
            tr.each_transform_port do |port, transform|
                next if has_final_information_for_port?(task, port.name)
                from = task.selected_frames[transform.from]
                to   = task.selected_frames[transform.to]
                add_port_info(task, port.name, TransformAnnotation.new(task, from, to))
                if from && to
                    done_port_info(task, port.name)
                else
                    has_all = false
                end
            end
            return has_all
        end

        def self.initialize_selected_frames(task, current_selection)
            if task.requirements
                new_selection = task.requirements.frame_mappings
            else
                new_selection = Hash.new
            end

            # If the task is associated to a device, check the frame
            # declarations on the device declaration
            if task.respond_to?(:each_device) && (tr = task.model.transformer)
                task.each_device do |srv, dev|
                    selected_frame = dev.frame
                    selected_transform = dev.frame_transform

                    # Two cases:
                    #  - the device is using the transformer (has frame
                    #    definitions). Assign the selected frame
                    #  - the device is NOT using the transformer. Therefore,
                    #    we must only add the relevant port info
                    #
                    # This part covers the part where we have to store the frame
                    # selection (first part). The second part is covered in
                    # #initial_information
                    srv.each_output_port(true) do |out_port|
                        # Do not associate the ports that output transformations
                        if selected_transform && Transformer.transform_port?(out_port)
                            from, to = selected_transform.from, selected_transform.to
                            if tr && (transform = tr.find_transform_of_port(out_port))
                                if from
                                    new_selection[transform.from] = from
                                end
                                if to
                                    new_selection[transform.to] = to
                                end
                            end
                        elsif selected_frame
                            if tr && (frame_name = tr.find_frame_of_port(out_port))
                                new_selection[frame_name] = selected_frame
                            end
                        end
                    end
                end
            end

            task.select_frames(current_selection.merge(new_selection))
        end
    end

    # Exception raised when a needed frame is not assigned
    class MissingFrame < RuntimeError; end

    # Module used to add some functionality to Orocos::RobyPlugin::Engine
    module EngineExtension
        def validate_generated_network(plan, options)
            super if defined? super

            plan.find_local_tasks(Orocos::RobyPlugin::TaskContext).each do |task|
                next if !(tr = task.model.transformer)
                tr.each_needed_transformation do |transform|
                    if !task.selected_frames[transform.from]
                        raise MissingFrame, "could not find a frame assignment for #{transform.from} in #{task}"
                    end
                    if !task.selected_frames[transform.to]
                        raise MissingFrame, "could not find a frame assignment for #{transform.to} in #{task}"
                    end
                end
            end
        end
    end

    Orocos::RobyPlugin::Engine.register_model_postprocessing do |system_model|
        # For every composition, ignore all dynamic_transformations ports
        system_model.ignore_port_for_autoconnection Orocos::Spec::InputPort, 'dynamic_transformations', '/base/samples/RigidBodyState'
    end

    Orocos::RobyPlugin::Engine.register_instanciation_postprocessing do |engine, plan|
        # Transfer the frame mapping information from the instance specification
        # objects to the selected_frames hashes on the tasks
        tasks = plan.find_local_tasks(Orocos::RobyPlugin::Component).roots(Roby::TaskStructure::Hierarchy)
        tasks.each do |root_task|
            FramePropagation.initialize_selected_frames(root_task, Hash.new)
            Roby::TaskStructure::Hierarchy.each_bfs(root_task, BGL::Graph::ALL) do |from, to, info|
                FramePropagation.initialize_selected_frames(to, from.selected_frames)
            end
        end
    end

    Orocos::RobyPlugin::Engine.register_instanciated_network_postprocessing do |engine, plan, validate|
        FramePropagation.compute_frames(plan)
    end
end

Orocos::RobyPlugin::Component.include Transformer::ComponentExtension
Orocos::RobyPlugin::TaskContext.include Transformer::TaskContextExtension
Orocos::RobyPlugin::DeviceInstance.include Transformer::DeviceExtension
Orocos::RobyPlugin::Graphviz.include Transformer::GraphvizExtension
Orocos::RobyPlugin::InstanceRequirements.include Transformer::InstanceRequirementsExtension
Orocos::RobyPlugin::Engine.include Transformer::EngineExtension
Roby.app.filter_out_patterns.push(/^#{Regexp.quote(__FILE__)}/)
