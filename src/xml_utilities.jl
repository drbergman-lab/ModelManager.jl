#! Generic XML utility functions used for XML-based variation infrastructure.
#! Requires LightXML.

using LightXML

################## XML Element Navigation ##################

"""
    getChildByAttribute(parent_element::XMLElement, path_element_split::Vector{<:AbstractString})

Get the child element of `parent_element` that matches the given tag and attribute.
"""
function getChildByAttribute(parent_element::XMLElement, path_element_split::Vector{<:AbstractString})
    path_element_name, attribute_name, attribute_value = path_element_split
    candidate_elements = get_elements_by_tagname(parent_element, path_element_name)
    for ce in candidate_elements
        if attribute(ce, attribute_name) == attribute_value
            return ce
        end
    end
    return nothing
end

"""
    getChildByChildContent(current_element::XMLElement, path_element::AbstractString)

Get the child element of `current_element` that matches the given tag and child content.
"""
function getChildByChildContent(current_element::XMLElement, path_element::AbstractString)
    tag, child_scheme = split(path_element, "::")
    tokens = split(child_scheme, ":")
    @assert length(tokens) == 2 "Invalid child scheme for $(path_element). Expected format: <tag>::<child_tag>:<child_content>"
    child_tag, child_content = tokens
    candidate_elements = get_elements_by_tagname(current_element, tag)
    for ce in candidate_elements
        child_element = find_element(ce, child_tag)
        if !isnothing(child_element) && content(child_element) == child_content
            return ce, true
        end
    end
    return current_element, false
end

"""
    retrieveElement(xml_doc::XMLDocument, xml_path::Vector{<:AbstractString}; required::Bool=true)

Retrieve the element in the XML document that matches the given path.

If `required` is `true`, an error is thrown if the element is not found.
Otherwise, `nothing` is returned if the element is not found.
"""
function retrieveElement(xml_doc::XMLDocument, xml_path::Vector{<:AbstractString}; required::Bool=true)
    current_element = root(xml_doc)
    for path_element in xml_path
        if contains(path_element, "::")
            current_element, success = getChildByChildContent(current_element, path_element)
            if !success
                current_element = nothing
            end
        else
            current_element = contains(path_element, ":") ?
                getChildByAttribute(current_element, split(path_element, ":"; limit=3)) :
                find_element(current_element, path_element)
        end

        if isnothing(current_element)
            required ? retrieveElementError(xml_path, path_element) : return nothing
        end
    end
    return current_element
end

"""
    retrieveElementError(xml_path::Vector{<:AbstractString}, path_element::String)

Throw an error if the element defined by `xml_path` is not found in the XML document, including the path element that caused the error.
"""
function retrieveElementError(xml_path::Vector{<:AbstractString}, path_element::String)
    error_msg = "Element not found: $(join(xml_path, " -> "))"
    error_msg *= "\n\tFailed at: $(path_element)"
    throw(ArgumentError(error_msg))
end

"""
    elementIsTerminal(e::XMLElement)

Check if an XML element is terminal (i.e., has no child elements).
Returns `true` if the element has no children, `false` otherwise.
"""
elementIsTerminal(e::XMLElement) = isempty(child_elements(e))

################## XML Content Accessors ##################

"""
    getSimpleContent(xml_doc::XMLDocument, xml_path::Vector{<:AbstractString}; required::Bool=true)

Get the content of the element in the XML document that matches the given path. See [`retrieveElement`](@ref).

Validates that the element is terminal (has no child elements) and contains non-empty text content.
Throws AssertionError if either condition is not met.
"""
function getSimpleContent(xml_doc::XMLDocument, xml_path::Vector{<:AbstractString}; required::Bool=true)
    e = retrieveElement(xml_doc, xml_path; required=required)
    @assert elementIsTerminal(e) "Element at path $(join(xml_path, " -> ")) has child elements and cannot have simple content extracted."
    ret_val = content(e)
    @assert !isempty(ret_val) "Element at path $(join(xml_path, " -> ")) has no text content."
    return ret_val
end

"""
    setSimpleContent(xml_doc::XMLDocument, xml_path::Vector{<:AbstractString}, new_value::Union{Int,Real,String})

Update the content of the element in the XML document that matches the given path with the new value. See [`retrieveElement`](@ref).

Validates that the element is terminal (has no child elements) before setting content. Throws AssertionError if the element has child elements.
"""
function setSimpleContent(xml_doc::XMLDocument, xml_path::Vector{<:AbstractString}, new_value::Union{Int,Real,String})
    e = retrieveElement(xml_doc, xml_path; required=true)
    @assert elementIsTerminal(e) "Element at path $(join(xml_path, " -> ")) is not a terminal element and has child elements. Cannot set content."
    set_content(e, string(new_value))
    return nothing
end

################## XML Path ↔ Column Name ##################

"""
    columnNameToXMLPath(column_name::String)

Return the XML path corresponding to the given column name.

Inverse of [`columnName`](@ref).
"""
columnNameToXMLPath(column_name::String) = split(column_name, "/")

################## Varied File Preparation ##################

"""
    prepareBaseFile(input_folder::InputFolder)
    prepareBaseFile(::AbstractSimulator, input_folder::InputFolder)

Return the path to the base input file for `input_folder`, or `nothing` if the folder has no
base file.

Default implementation: `joinpath(locationPath(input_folder), input_folder.basename)`, or
`nothing` if `input_folder.basename` is `missing`.

Simulator packages may override `prepareBaseFile(::TheirSimulator, input_folder)` for
location types that require special handling (e.g. generating a base file on demand).
"""
prepareBaseFile(input_folder::InputFolder) = prepareBaseFile(simulator(), input_folder)
function prepareBaseFile(::AbstractSimulator, input_folder::InputFolder)
    ismissing(input_folder.basename) ? nothing : joinpath(locationPath(input_folder), input_folder.basename)
end

"""
    postVariationXMLProcessing(location::Symbol, path_to_xml::String)
    postVariationXMLProcessing(::AbstractSimulator, location::Symbol, path_to_xml::String)

Hook called immediately after [`createXMLFile`](@ref) writes a variation XML file at
`path_to_xml` for `location`. Default is a no-op.

Simulator packages may override `postVariationXMLProcessing(::TheirSimulator, location, path)`
for location-specific post-processing (e.g. splitting out embedded SBML files).
"""
postVariationXMLProcessing(location::Symbol, path_to_xml::String) =
    postVariationXMLProcessing(simulator(), location, path_to_xml)
postVariationXMLProcessing(::AbstractSimulator, ::Symbol, ::String) = nothing

"""
    createXMLFile(location::Symbol, M::AbstractMonad)

Create (if needed) the variation XML file for `location` in monad `M` and return its path.

The file is written to `<location_folder>/<variations_subfolder>/<location>_variation_<id>.xml`.
If the file already exists it is returned immediately. After writing, calls
[`postVariationXMLProcessing`](@ref) to allow simulator-specific post-processing.
"""
function createXMLFile(location::Symbol, M::AbstractMonad)
    @assert M.inputs[location].varied "Folder $(locationPath(location, M)) is not varied and should not have an XML file created for it."
    path_to_folder = locationPath(location, M)
    path_to_xml = joinpath(path_to_folder, locationVariationsFolder(location), "$(location)_variation_$(M.variation_id[location]).xml")
    if isfile(path_to_xml)
        return path_to_xml
    end
    mkpath(dirname(path_to_xml))

    path_to_base_xml = prepareBaseFile(M.inputs[location])
    @assert endswith(path_to_base_xml, ".xml") "Base XML file for $(location) must end with .xml. Got $(path_to_base_xml)"
    @assert isfile(path_to_base_xml) "Base XML file not found: $(path_to_base_xml)"

    xml_doc = parse_file(path_to_base_xml)
    if M.variation_id[location] != 0
        query = constructSelectQuery(locationVariationsTableName(location), "WHERE $(locationVariationIDName(location))=$(M.variation_id[location])")
        variation_row = queryToDataFrame(query; db=locationVariationsDatabase(location, M), is_row=true)
        for column_name in names(variation_row)
            if column_name == locationVariationIDName(location) || column_name == "par_key"
                continue
            end
            xml_path = columnNameToXMLPath(column_name)
            setSimpleContent(xml_doc, xml_path, variation_row[1, column_name])
        end
    end
    save_file(xml_doc, path_to_xml)
    free(xml_doc)
    postVariationXMLProcessing(location, path_to_xml)
    return path_to_xml
end

"""
    prepareVariedInputFolder(location::Symbol, M::AbstractMonad)

Create the variation XML file for `location` in monad `M`, if the location is varied.
"""
function prepareVariedInputFolder(location::Symbol, M::AbstractMonad)
    if !M.inputs[location].varied
        return
    end
    createXMLFile(location, M)
end

"""
    prepareVariedInputFolder(location::Symbol, sampling::Sampling)

Create the variation XML file for each monad in `sampling` for `location`, if varied.
"""
function prepareVariedInputFolder(location::Symbol, sampling::Sampling)
    if !sampling.inputs[location].varied
        return
    end
    for monad in Monad.(constituentIDs(sampling))
        prepareVariedInputFolder(location, monad)
    end
end
