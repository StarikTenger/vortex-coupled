# Context

I refactored vortex code trying to align timing behavior with functional. In original version the functional execution including fetching decoding, performaing operations and accessing memory was done atomically in schedule stage. The timing stages were only handilng metainformation about instructions. In my version I am performing each functional step in the corresponding timing stage to facilitate future integration with gem5 emulator.

# Testing

Currently I am verifying my design using the tests from tests/regression. I have run the all the test using the script util/run-tests.sh from the build/ folder. 

Importantly, I run the simx core with debug=0, if this flag is not enabled, more tests are to fail, I don't know why.

The results of the test are following: 

basic PASS
conv3 PASS
cta PASS
demo PASS
diverge FAIL
dogfood FAIL
dotproduct PASS
dropout FAIL
fence PASS
io_addr FAIL
madmax PASS
mstress PASS
printf PASS
relu PASS
sgemm PASS
sgemm_tcu FAIL
sgemm2 PASS
sgemv PASS
sort PASS
stencil3d PASS
vecadd PASS

I want you to investigate why the tests are failing. For that I want you do the following.

For each tests which fails (according to the list above) do following steps:
- Investigate the code of the test. Can be found in tests/tegression/testname. Normally, test should consist of host code (main.cpp), kernel code (kernel.cpp) and maybe some other files. From my understanding, the tests run the kernel code in simulator, run same functions on host and compare the results. For the tests I want a brief explanation of what tests is doing, which functionality is targeted.
- Run the test. To see how to run the tests, consult .vscode/launch.json. It has information about how to run dogfood test. Must be the same for other. Use this json just as a reference to craft a command for running.
- Collect and analyse the trace. Which tests are failing? Find the fragments in code which are likely to be the cause of the failure.
- Propose explanations for why the failutre might be happening.

Once you are done with all the tests, analyse all the results together, find similarities and common points.

# General guidelines

Create a separate folder fot this experiments where you put your notes along with traces and any additional scripts you might use. In this folder I expect to have a markdown file with a report. Follow a clear report structure mentioning the scope, outline. Include a table with brief description of results. Clearly divide facts from hypothesis (using constructions as "I think", "it might be that" and so on). Do not go yourself into researching out of te scope unless I explicitly tell you to do so. Nevertheless, if you have any ideas of what other aspects should be investigated, tell me and add a section about it in the report.