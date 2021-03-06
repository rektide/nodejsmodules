require('js-yaml')
mongoose = require('mongoose')
url = require('url')
request = require('request')
logger = require('winston')
_ = require('underscore')
NpmPackage = require('./model/NpmPackage')
config = require('./config')

mongoose.connect(config.mongodb)

# metrics {
# gompertz(max, xdisp, growth, x) = max*e^(-xdisp*e^(-growth*x))
# sigmoid(max, growth, x) = max*((2/(1+e^(-growth*2*x)))-1)
# githubInterest: sigmoid(25, 0.01, stars) + sigmoid(75, 0.01, forks)
# githubFreshness: max - gompertz(max, xdisp, decay, days(ghLastIndexed - lastPush)) # max: 100, decay: 0.01, xdisp: 5
# npmFreshness: max - gompertz(max, xdisp, decay, days(npmLastIndexed - lastVersion)) # max: 100, decay: 0.01, xdisp: 5
# npmNewness: max - npmMaturity # max: 100, decay: 0.01, xdisp: 5
# npmMaturity: gompertz(max, xdisp, decay, days(npmLastIndexed - firstVersion)) # max: 100, decay: 0.01, xdisp: 5 
# npmFrequency: gompertz(max, xdisp, decay, commitsPerYearBetween(npmLastIndexed, firstCommit) # max 100, decay: 0.15, xdisp: 6
# npmInterest: 0.5*sigmoid(0.000006, downloads.total) + 0.5*sigmoid(0.00004,downloads.month)
#
# authorScore: sum
#
# interest: more weighted to forks, stars, newness, etc. than revdeps
# popular: more weighted to revdeps than forks, stars, newness, etc.
# new: more weighted to newness, freshness, author score


gompertz = (max, xdisp, growth, x) -> max * Math.exp(-xdisp*Math.exp(-growth * x))
sigmoid = (max, growth, x) -> max * ((2/(1+Math.exp(-growth*2*x)))-1)

days = (ms) -> ms/(24*60*60*1000)

githubInterest = (doc) -> if doc.github?.exists then sigmoid(75, 0.01, doc.github.stars) + sigmoid(25, 0.01, doc.github.forks) else 0

githubFreshness = (doc) ->
  if not doc.github?.exists
    return 0

  difference = days(doc.github.lastIndexed - doc.github.lastPush)
  100 - gompertz(100, 5, 0.01, difference)

npmFreshness = (doc) ->
  recentVersion = doc.orderedVersions[-1..][0]
  difference = days(doc.lastIndexed - recentVersion.time)
  100 - gompertz(100, 5, 0.01, difference)

npmMaturity = (doc) ->
  earliestVersion = doc.orderedVersions[0]
  difference = days(doc.lastIndexed - earliestVersion.time)
  gompertz(100, 5, 0.01, difference)

npmNewness = (doc) -> 100 - npmMaturity(doc)

npmFrequency = (doc) ->
  earliestVersion = doc.orderedVersions[0]
  difference = days(doc.lastIndexed - earliestVersion.time)
  count = doc.orderedVersions.length
  cpy = (count / difference) * 365

  gompertz(100, 6, 0.15, cpy)


npmInterest = (doc) -> sigmoid(50, 0.000006, doc.downloads.total) + sigmoid(50, 0.00004, doc.downloads.month)

preprocess = (doc) ->
  doc.orderedVersions = _.sortBy(doc.versions, 'time')
  if doc.orderedVersions.length == 0
    return false

  return true

docs = {}

waiting = 1

exitIfDone = () =>
  waiting -= 1
  if(waiting == 0)
    mongoose.connection.close()

stream = NpmPackage.find().sort({"$natural": -1}).stream()
stream.on('data', (doc) =>
  console.log("Processing #{doc.id}...")

  doc.metrics = {} unless doc.metrics?
  doc.metrics.githubInterest = 0
  doc.metrics.githubFreshness = 0
  doc.metrics.npmFreshness = 0
  doc.metrics.npmNewness = 0
  doc.metrics.npmFrequency = 0
  doc.metrics.npmInterest = 0

  if preprocess(doc)
    doc.metrics.githubInterest = githubInterest(doc)
    doc.metrics.githubFreshness = githubFreshness(doc)
    doc.metrics.npmFreshness = npmFreshness(doc)
    doc.metrics.npmMaturity = npmMaturity(doc)
    doc.metrics.npmNewness = npmNewness(doc)
    doc.metrics.npmFrequency = npmFrequency(doc)
    doc.metrics.npmInterest = npmInterest(doc)

  doc.save(exitIfDone)
  waiting += 1
)

stream.on('error', (error) =>
  console.log(error)
  process.exit()
)

stream.on('close', exitIfDone)
