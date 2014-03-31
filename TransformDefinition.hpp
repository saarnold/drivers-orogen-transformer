#ifndef TRANSFORMDEFINITION_HPP
#define TRANSFORMDEFINITION_HPP

#include <string>
namespace transformer
{
    struct TransformDefinition
    {
        std::string source_frame;
        std::string target_frame;
    };
}

#endif

