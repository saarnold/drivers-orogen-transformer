#ifndef TRANSFORMER_STATUS_HPP
#define TRANSFORMER_STATUS_HPP

#include <transformer/TransformationStatus.hpp>
#include <vector>

namespace transformer
{
    /** Report of status for all transformations registered on a particular
     * oroGen component
     */
    struct TransformerStatus
    {
        base::Time time;
        std::vector<transformer::TransformationStatus> transformations;
    };
}

#endif

