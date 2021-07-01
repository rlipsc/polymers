#[
  Simple ECS plugin for adding a Killed component after some delay.
  This allows you to mark entities for clean up for example by using Killed
  as a system requirement. 
]#

import polymorph

template defineKilling*(componentOptions: static[ECSCompOptions]): untyped {.dirty.} =

  registerComponents(componentOptions):
    type
      KillAfter* = object
        duration*: float
        ## Set automatically.
        startTime*: float
      Killed* = object
        source*: EntityRef
  
  KillAfter.onInit:
    curComponent.startTime = cpuTime()

template addKillingSystems*(systemOptions: static[ECSSysOptions]): untyped =
  # To effectively use a killed tag, it is desirable to be able to decide
  # where they are ultimately removed so that you can process Killed in your
  # own systems first.
  defineSystem("killAfter", [KillAfter], systemOptions)
  defineSystem("deleteKilled", [Killed], systemOptions)

  import times

  # This system's run order is fairly independent so hasn't been separated out to another template.
  makeSystemBody("killAfter"):
    start:
      let curTime = cpuTime()
    all:
      if curTime - item.killAfter.startTime >= item.killAfter.duration:
        item.entity.addComponent Killed()

  makeSystemBody("deleteKilled"):
    all:
      # Entities tagged with Killed are now removed.
      deleteEntity()

