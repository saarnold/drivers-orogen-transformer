#ifndef TRANSFORMER_BROADCAST_TYPES_HPP
#define TRANSFORMER_BROADCAST_TYPES_HPP

#include <string>
#include <base/samples/RigidBodyState.hpp>
#include <vector>

namespace transformer {
    
    struct TransformationDescription
    {
        std::string sourceFrame;
        std::string targetFrame;
    };
    
    struct PortFrameAssociation
    {
        std::string task;
        std::string port;
        std::string frame;

        PortFrameAssociation() {}
        PortFrameAssociation(std::string const& task, std::string const& port,
                std::string const& frame)
            : task(task), port(port) , frame(frame) {}

        bool operator == (PortFrameAssociation const& other) const
        { return task == other.task && port == other.port && frame == other.frame; }
    };

    struct PortTransformationAssociation
    {
        std::string task;
        std::string port;
        std::string from_frame;
        std::string to_frame;

        PortTransformationAssociation() {}
        PortTransformationAssociation(std::string const& task, std::string const& port,
                std::string const& from_frame, std::string const& to_frame)
            : task(task), port(port)
            , from_frame(from_frame), to_frame(to_frame) {}

        bool operator == (PortTransformationAssociation const& other) const
        { return task == other.task && port == other.port && from_frame == other.from_frame && to_frame == other.to_frame; }
    };

    struct ConfigurationState
    {
        std::vector<PortFrameAssociation> port_frame_associations;
        std::vector<PortTransformationAssociation> port_transformation_associations;
        std::vector<base::samples::RigidBodyState> static_transformations;
    };
}

#endif
