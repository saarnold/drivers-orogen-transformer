require 'transformer'

module Transformer
    logger.level = Logger::DEBUG

    # Module used to extend the device specification objects with the ability
    # to specify frames
    #
    # The #frame attribute allows to specify in which frame this device
    # produces information.
    module DeviceExtension
        ## 
        # Declares the frame in which this device produces data
        dsl_attribute :frame
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
        end
    end

    # Module used to extend objects of the class Orocos::RobyPlugin::TaskContext
    module TaskContextExtension
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

        # Don't merge two tasks if they have different frame selections
        def can_merge?(merged_task)
            if !(merge_result = super)
                return merge_result
            end

            selected_frames.each do |frame_name, selected_frame|
                if merged_task.selected_frames[frame_name] != selected_frame
                    return false
                end
            end
            return true
        end

        def merge(merged_task)
            selected_frames.merge!(merged_task.selected_frames) do |k, v1, v2|
                if v1 != v2
                    raise FrameMismatch, "cannot merge #{merged_task} into #{self} as different frames are selected for #{k}: resp. #{v1} and #{v2}"
                end
                v1
            end
            super
        end

        # Module that extends the TaskContext class itself
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
        def add_transforms_annotations
            plan.find_local_tasks(Orocos::RobyPlugin::TaskContext).each do |task|
                tr = task.model.transformer
                if task.kind_of?(Orocos::RobyPlugin::Device)
                    task.each_device do |srv, dev|
                        next if !(selected_frame = dev.frame)

                        # Two cases:
                        #  - the device is using the transformer (has frame
                        #    definitions) and declared a link between the frame
                        #    and the output port. This is handled later.
                        #  - the device is NOT using the transformer. Add the
                        #    vertex and edge now
                        srv.each_output_port(true) do |out_port|
                            if !tr || !tr.find_frame_of_port(out_port)
                                add_vertex(task, "frames_#{dev.name}", "label=\"dev(#{dev.name})=#{selected_frame}\",shape=ellipse")
                                add_edge(["frames_#{dev.name}", task], [out_port, task], "dir=none")
                            end
                        end
                    end
                end

                if tr
                    edges = Set.new
                    tr.each_frame do |frame|
                        add_vertex(task, "frames_#{frame}", "label=\"#{frame}=#{task.selected_frames[frame]}\",shape=ellipse")
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
                @from ||= ann.from
                @to   ||= ann.to
                if ann.from != from
                    raise FrameMismatch, "incompatible selection: #{ann.from} != #{@from}"
                end
                if ann.to != to
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
            tasks.each do |t|
                t.selected_frames.clear
            end
            algorithm.propagate(plan.find_tasks(Orocos::RobyPlugin::TaskContext).to_value_set)
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

        def triggering_port_connections(task)
            return if !(tr = task.model.transformer)

            result = Hash.new
            connections = Set.new

            tr.each_annotated_port do |port, frame|
                task.each_concrete_input_connection(port.name) do |source_task, source_port, _|
                    connections << [source_task, source_port]
                end
                task.each_concrete_output_connection(port.name) do |_, sink_port, sink_task, _|
                    connections << [sink_task, sink_port]
                end

                if !connections.empty?
                    result[port.name] = [connections, true]
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
                    next if !(selected_frame = dev.frame)

                    # Two cases:
                    #  - the device is using the transformer (has frame
                    #    definitions). Assign the selected frame
                    #  - the device is NOT using the transformer. Therefore,
                    #    we must only add the relevant port info
                    srv.each_output_port(true) do |out_port|
                        if tr && (frame_name = tr.find_frame_of_port(out_port))
                            task.select_frame(frame_name, selected_frame)
                        else
                            add_port_info(task, out_port.name, FrameAnnotation.new(task, frame_name, selected_frame))
                            done_port_info(task, out_port.name)
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
                    puts "BLAAAH #{task} #{port.name} #{port_info(task, port.name).selected_frame}"
                    task.select_frame(frame, port_info(task, port.name).selected_frame)
                    puts "  " + task.selected_frames.inspect
                end
            end
            tr.each_transform_port do |port, transform|
                next if !has_information_for_port?(task, port.name)
                from = task.selected_frames[transform.from]
                to   = task.selected_frames[transform.to]
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
    end

    Orocos::RobyPlugin::Engine.register_instanciation_postprocessing do |engine, plan|
        FramePropagation.compute_frames(plan)
    end
    # Orocos::RobyPlugin::Engine.register_instanciation_postprocessing do |engine, plan|
    #     # Transfer the frame mapping information from the instance specification
    #     # objects to the selected_frames hashes on the tasks
    #     tasks = plan.find_local_tasks(Orocos::RobyPlugin::Component).roots(Roby::TaskStructure::Hierarchy)
    #     tasks.each do |root_task|
    #         root_task.select_frames(root_task.instance_spec.selected_frames)
    #         root_task.each_bfs(Roby::TaskStructure::Hierarchy, BGL::Graph::ALL) do |from, to, info|
    #             if to.instance_spec
    #                 current_selection = from.selected_frames.merge(to.instance_spec.selected_frames)
    #                 to.select_frames(current_selection)
    #             else
    #                 to.select_frames(from.selected_frames)
    #             end
    #         end
    #     end
    # end

    # Orocos::RobyPlugin::Engine.register_instanciated_network_postprocessing do |engine, plan|
    #     FramePropagation.compute_frames(plan)
    # end
end

Orocos::RobyPlugin::TaskContext.include Transformer::TaskContextExtension
Orocos::RobyPlugin::DeviceInstance.include Transformer::DeviceExtension
Orocos::RobyPlugin::Graphviz.include Transformer::GraphvizExtension
