#include <boost/version.hpp>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/graphviz.hpp>
#include <boost/xpressive/xpressive.hpp>
#include <sstream>
#include <string>
#include <vector>

static_assert(BOOST_VERSION == 108300, "The test must use the declared Boost 1.83 SDK");

int verify_template_headers() {
    boost::adjacency_list<> graph(2);
    boost::add_edge(0, 1, graph);
    std::ostringstream dot;
    boost::write_graphviz(dot, graph);
    const std::string value = "p4c83";
    const auto expression = boost::xpressive::sregex::compile("p4c[0-9]+");
    std::vector<int> vertices;
    vertices.push_back(2);
    return boost::xpressive::regex_match(value, expression) &&
                   dot.str().find("0->1") != std::string::npos && vertices[0] == 2
               ? 0
               : 1;
}
