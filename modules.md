This is a live document! Check regularly for updates ...

# Kartta Labs Modules
This document outlines the self-contained modules that together support a scalable system for
georeferencing and vectorizing scanned historical map images. The input to the system is a scanned
historical map (a raster map), and the output is a georeferenced vector dataset (e.g., in GeoJSON), which 
can be used to fully re-render the input map in customized cartographic styles.

## Background
The mission of Kartta Labs is to organize the world’s historical maps and make them universally accessible 
(e.g., searchable by location, time, and keywords) and useful (e.g., map contents are usable in an analytic 
environment, such as a Geographic Information System). The final product is an open-source map server with a 
time dimension. This map server will let users request a map for a certain location (e.g., in latitude and 
longitude coordinates or place names) along with a given time (e.g., the year 1942) and receive the 
corresponding map data (either in raster or vector map tiles). We are developing a stack of tools to 
crowdsource this process (i.e., from scanned historical maps to the final product of Kartta Labs) as well as 
intelligent algorithms to facilitate/automate the process. We will define the modules in this document achieve
our goal step-bystep. In the final product, crowdsourcing and the automated intellignet modules defined in this
document will complement each other.

## Modules
Each module is defined to do a single and specific task independently from the rest of the modules. Each 
module is defined by its input and output (i/o). The definition comes with a brief description, possible challenges,
and the success criteria. Initial ideas for implementing individual modules are given but the implementation should not
affect the i/o of the module. We intend to run these modules as Google Cloud Functions such that our web
application can call any of these functions without worrying about scaling issues. Note that Cloud Functions
also lets chaining the functions which can be used to make larger modules out of smaller ones. Often the
output of one module becomes the input of another.

