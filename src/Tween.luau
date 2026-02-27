--[=[
	@class DynamicTween
	
	DynamicTimer 기반 시간축을 따르며 Delay, 반복, 역재생, Instance 속성 매핑 등을 지원하는 범용 Tween 객체입니다.
	`Class.RunService.Heartbeat`, `Class.RunService.RenderStepped`, `Class.RunService.PostSimulation` `Class.RunService.PreSimulation` 신호 또는 사용자 정의 StepEvent 위에서 원하는 값 타입을 선형 보간합니다.

	<Alert severity="Warning">
	일반적인 Tween 은 `DynamicTimer.GlobalTimer:CreateTween` 으로 공유 타이머를 활용하는 편이 안전합니다.
	</Alert>
]=]

local RunService = game:GetService("RunService")

local LinearInterpolation = require("../roblox_packages/LinearInterpolation")
local Maid = require("../roblox_packages/Maid")
local MathUtil = require("../roblox_packages/MathUtil")
local Signal = require("../roblox_packages/Signal")

local easingsByStyleAndDirection = MathUtil.easingsByStyleAndDirection

local DynamicTween = {}
DynamicTween.__index = DynamicTween
DynamicTween.__type = "DynamicTween"

type PlaySnapshot = {
	Type: "Play" | "Pause",
	Time: number,
	LastProgress: number,
}

export type DynamicTween<DynamicTimer = any, Value = any> = setmetatable<
	{
		--- 트윈이 Destroy 호출로 정리되었는지 여부입니다.
		IsDestroyed: boolean,

		--- 현재 StepEvent 업데이트에 참여 중인지 여부입니다.
		IsPlaying: boolean,

		--- 종료 콜백이 호출되고 반복 주기가 모두 끝났는지 여부입니다.
		IsFinished: boolean,

		--- 연결된 DynamicTimer 입니다. TimeScale, 되감기 등이 반영됩니다.
		Timer: DynamicTimer,

		--- 내부 연결과 Signal 을 정리하기 위한 Maid 입니다.
		Maid: Maid.Maid,

		--- 트윈이 생성된 시점의 타이머 경과 시간(초)입니다.
		CreationTime: number,

		--- 현재까지 누적된 진행 시간입니다. 반복, Delay 를 모두 포함합니다.
		ProgressTime: number,

		--- 한 사이클에 실제로 보간이 일어나는 시간(초)입니다.
		Duration: number,

		--- MathUtil 에 정의된 이징 스타일입니다.
		EasingStyle: MathUtil.EasingStyle,

		--- MathUtil 에 정의된 이징 방향(In, Out, InOut 등)입니다.
		EasingDirection: MathUtil.EasingDirection,

		--- 보간된 값이 갱신될 때 호출되는 콜백입니다.
		Callback: (value: Value) -> ()?,

		--- `Class.RunService.Heartbeat`, `Class.RunService.RenderStepped`, 사용자 정의 Signal 등 업데이트 이벤트입니다.
		StepEvent: StepEvent,

		--- 보간 시작 값입니다.
		Start: Value,

		--- 보간 목표 값입니다.
		Goal: Value,

		--- 최근 콜백 호출 시 전달된 현재 값입니다.
		CurrentValue: Value,

		--- 추가로 반복할 횟수입니다. -1 이면 무한 반복입니다.
		RepeatCount: number,

		--- true 면 왕복(역재생) 모드로 진행합니다.
		Reverses: boolean,

		--- 각 사이클 사이에 추가되는 대기 시간입니다.
		DelayTime: number,

		--- Play 호출 시 발동되는 Signal 입니다.
		Playing: Signal.Signal<>,

		--- 모든 진행이 끝났을 때 발동되는 Signal 입니다.
		Completed: Signal.Signal<>,

		_playSnapshots: { PlaySnapshot },
		_historyExpirationTime: number,
		_lastObservedElapsedTime: number,
	},
	typeof(DynamicTween)
>

local function getProgress(self: DynamicTween, progressTime: number): number
	local easing = easingsByStyleAndDirection[self.EasingStyle][self.EasingDirection]
	local progress

	local duration = self.Duration
	local delayTime = self.DelayTime

	if duration <= 0 then
		if delayTime <= 0 then
			return easing(if self.Reverses then 0 else 1)
		end

		if not self.Reverses then
			return easing(1)
		end

		local cycleProgressTime = progressTime % (delayTime * 2)
		return easing(if cycleProgressTime < delayTime then 1 else 0)
	end

	if not self.Reverses then
		local cycleDuration = duration + delayTime
		local cycleProgressTime = progressTime % cycleDuration
		progress = if cycleProgressTime < duration then cycleProgressTime / duration else 1
	else
		local cycleDuration = (duration + delayTime) * 2
		local cycleProgressTime = progressTime % cycleDuration

		if cycleProgressTime < duration then
			progress = cycleProgressTime / duration
		elseif cycleProgressTime < duration + delayTime then
			progress = 1
		elseif cycleProgressTime < duration * 2 + delayTime then
			progress = 1 - (cycleProgressTime - (duration + delayTime)) / duration
		else
			progress = 0
		end
	end

	return easing(progress)
end

local function runCallback(self: DynamicTween, progress)
	local value = self.Interpolation(self.Start, self.Goal, progress)
	self.CurrentValue = value
	task.spawn(self.Callback, value)
end

local function complete(self: DynamicTween)
	self.Completed:Fire()
end

local function finish(self: DynamicTween)
	if self.IsFinished then
		return
	end

	self.IsFinished = true

	local finalProgress
	if self.Reverses then
		finalProgress = 0
	else
		finalProgress = 1
	end
	runCallback(self, finalProgress)

	self.IsPlaying = false
	complete(self)
	self._historyExpirationTime = self.Timer.ElapsedTime + self.Timer.HISTORY_RETETION_DURATION
end

local function clearPlaybackHistory(self: DynamicTween)
	table.clear(self._playSnapshots)
	self.ProgressTime = 0
	self.IsPlaying = false
	self.IsFinished = true
	self._historyExpirationTime = math.huge
end

local function getMaxDuration(self: DynamicTween): number
	if self.RepeatCount < 0 then
		return math.huge
	end

	local totalRepeats = self.RepeatCount + 1
	local cycleDuration = self.Duration + self.DelayTime

	local maxDuration = cycleDuration * totalRepeats - self.DelayTime
	if self.Reverses then
		maxDuration = (cycleDuration * 2) * totalRepeats - self.DelayTime
	end

	return maxDuration
end

local function onElapsedTimeChanged(self: DynamicTween, newTime: number)
	if self.IsDestroyed then
		return
	end

	self._lastObservedElapsedTime = newTime

	if newTime < self.CreationTime then
		self:Destroy()
		return
	end

	if
		self.IsFinished
		and self._historyExpirationTime ~= math.huge
		and newTime >= self._historyExpirationTime
	then
		clearPlaybackHistory(self)
		return
	end

	local snapshots = self._playSnapshots
	while #snapshots > 0 and snapshots[#snapshots].Time > newTime do
		table.remove(snapshots)
	end

	local newProgressTime = 0
	local newIsPlaying = false
	local lastPlaySnapshot: PlaySnapshot? = nil

	for _, snapshot in ipairs(snapshots) do
		if snapshot.Type == "Play" then
			lastPlaySnapshot = snapshot
			newProgressTime = snapshot.LastProgress
			newIsPlaying = true
		elseif snapshot.Type == "Pause" then
			newProgressTime = snapshot.LastProgress
			lastPlaySnapshot = nil
			newIsPlaying = false
		end
	end

	if lastPlaySnapshot then
		newProgressTime = lastPlaySnapshot.LastProgress + (newTime - lastPlaySnapshot.Time)
		newIsPlaying = true
	end

	local maxDuration = getMaxDuration(self)
	newProgressTime = math.max(0, newProgressTime)

	if newProgressTime >= maxDuration then
		newProgressTime = maxDuration
		self.ProgressTime = newProgressTime

		if not self.IsFinished then
			finish(self)
		else
			self.IsPlaying = false
		end
		return
	end

	if self.IsFinished then
		self.IsFinished = false
		self._historyExpirationTime = math.huge
	end

	self.ProgressTime = newProgressTime
	self.IsPlaying = newIsPlaying

	if not self.IsPlaying then
		return
	end

	runCallback(self, getProgress(self, newProgressTime))
end

-- 시간 점프에 즉각 반응하기 위해 ElapsedTimeChanged에 연결합니다.
local function connectToTimer(self: DynamicTween)
	self.Maid:GiveTask(self.Timer.ElapsedTimeChanged:Connect(function(newTime)
		onElapsedTimeChanged(self, newTime)
	end))
end

--[=[
	@type
	StepEvent 는 트윈을 업데이트할 이벤트 소스 타입입니다.
	Signal 또는 Roblox 이벤트 객체도 사용할 수 있습니다.
]=]
type StepEvent =
	| "Heartbeat"
	| "RenderStepped"
	| "Stepped"
	| "PostSimulation"
	| "PreSimulation"
	| Signal.Signal
	| RBXScriptSignal

--[=[
	@interface DynamicTween.BaseDynamicTweenParams
	트윈 생성 시 공통으로 사용하는 선택 인자입니다.
]=]
export type BaseDynamicTweenParams<DynamicTimer = any> = {
	--- 기본값 1초. 하나의 이징 사이클 길이입니다.
	Duration: number?,

	--- @default "Cubic"
	EasingStyle: MathUtil.EasingStyle?,

	--- @default "InOut"
	EasingDirection: MathUtil.EasingDirection?,

	--- @default "Heartbeat"
	StepEvent: StepEvent?,

	--[=[
		-1 을 넣으면 무한 반복.
		@default 0
	]=]
	RepeatCount: number?,
	--[=[
		true 면 반복마다 역재생합니다.
		@default false
	]=]
	Reverses: boolean?,

	--[=[
		각 반복 사이에 추가 대기 시간을 부여합니다.
		@default 0
	]=]
	DelayTime: number?,
}

--[=[
	@interface
	값 보간에 필요한 필수·선택 인자입니다.
]=]
export type DynamicTweenParams<Value = number> = {
	--- @default 0
	Start: Value?,
	--- @default 1
	Goal: Value?,

	--[=[
		각 업데이트마다 호출되는 필수 콜백입니다, 
		반환되는 value는 Start와 Goal 사이의 보간된 값입니다.
	]=]
	Callback: (value: Value) -> (),
	--[=[
		값 타입용 보간 함수. 기본적으로 타입에서 추론합니다
	]=]
	Interpolation: LinearInterpolation.Interpolation<Value>?,
} & BaseDynamicTweenParams

local function createDynamicTween<Value>(
	timer: any,
	params: DynamicTweenParams<Value>
): DynamicTween<Value>
	local self = setmetatable({}, DynamicTween)

	self.Timer = timer
	self.Maid = Maid.new()

	self.IsDestroyed = false
	self.IsPlaying = false
	self.IsFinished = false

	self.CreationTime = self.Timer.ElapsedTime
	self.ProgressTime = 0

	self.Duration = params.Duration or 1
	self.EasingStyle = params.EasingStyle or "Cubic"
	self.EasingDirection = params.EasingDirection or "InOut"

	self.Start = params.Start or 0
	self.Goal = params.Goal or 1

	self.Callback = params.Callback or error("Missing Callback")
	self.StepEvent = params.StepEvent or "Heartbeat"

	self.Interpolation = params.Interpolation
		or LinearInterpolation.GetFunctionFromValueType(self.Start)

	self.RepeatCount = params.RepeatCount or 0
	self.Reverses = params.Reverses or false
	self.DelayTime = params.DelayTime or 0

	self.Playing = Signal.new()
	self._playSnapshots = {}
	self._historyExpirationTime = math.huge
	self._lastObservedElapsedTime = self.CreationTime

	self.Completed = Signal.new()
	self.Maid:GiveTask(self.Playing, self.Completed)

	connectToTimer(self)

	return self
end

--[=[
	@class DynamicTweenFromInstance
	@extends DynamicTween
	
	인스턴스로부터 파생된 트윈입니다.
	`Class.TweenService:Create(instance, tweenInfo, propertyMap)` 와 비슷한 인터페이스를 제공하기 위함입니다.
]=]
export type DynamicTweenFromInstance = {
	--- Instance Property 트윈을 위해 Instance 참조를 추가로 보관합니다.
	Instance: Instance,
} & DynamicTween<number>

local function createDynamicTweenFromInstance(
	timer: any,
	instance: Instance,
	params: BaseDynamicTweenParams,
	propertyMap: { [string]: any }
): DynamicTweenFromInstance
	local interpolations = {}
	local i = 0
	for property, goalValue in propertyMap do
		i += 1

		local initialValue = instance[property]
		local lerp = LinearInterpolation.GetFunctionFromValueType(initialValue)

		interpolations[i] = function(alpha)
			instance[property] = lerp(initialValue, goalValue, alpha)
		end
	end

	local self = createDynamicTween(timer, {
		Start = 0,
		Goal = 1,
		Duration = params.Duration,

		Callback = function(alpha)
			for _, interpolation in ipairs(interpolations) do
				interpolation(alpha)
			end
		end,
		EasingStyle = params.EasingStyle,
		EasingDirection = params.EasingDirection,

		StepEvent = params.StepEvent,
		RepeatCount = params.RepeatCount,
		Reverses = params.Reverses,
		DelayTime = params.DelayTime,
	})

	self.Instance = instance

	return self
end

--[=[
	트윈을 파괴하고 내부 Signal 및 연결을 정리합니다.
]=]
function DynamicTween:Destroy()
	if self.IsDestroyed then
		return
	end

	self.IsDestroyed = true
	self.IsPlaying = false
	self.Maid:Destroy()

	table.freeze(self :: any)
end

local function update(self: DynamicTween, dt: number)
	local maxDuration = getMaxDuration(self)
	local currentTweenTime = self.ProgressTime + dt

	if currentTweenTime >= maxDuration then
		self.ProgressTime = maxDuration
		finish(self)
		return
	end

	self.ProgressTime = currentTweenTime
	runCallback(self, getProgress(self, currentTweenTime))
end

local function updateUntilNotPlaying(self: DynamicTween)
	local stepEvent = self.StepEvent

	local event = if typeof(stepEvent) == "string" then RunService[stepEvent] else stepEvent

	local connection
	connection = event:Connect(function()
		if not self.IsPlaying then
			connection:Disconnect()
			self.Maid:RemoveTask(connection)
			return
		end

		local currentTime = self.Timer:GetElapsedTime()
		local dt = currentTime - self._lastObservedElapsedTime

		self._lastObservedElapsedTime = currentTime

		update(self, dt)
	end)
	self.Maid:GiveTask(connection)
end

--[=[
	진행 시간을 유지한 채 트윈을 재생합니다.
	되감기가 발생했으면 Timer 기록을 기반으로 ProgressTime 을 다시 맞춥니다.
]=]
function DynamicTween:Play()
	if self.IsPlaying then
		warn(`DynamicTween "{self}" is playing already.`)
		return
	end

	if self.IsDestroyed then
		warn(`DynamicTween "{self}" is destroyed.`)
		return
	end

	if self.IsFinished then
		warn(`DynamicTween "{self}" is Finished.`)
		return
	end

	local currentTime = self.Timer:GetElapsedTime()

	self._historyExpirationTime = math.huge
	self._lastObservedElapsedTime = currentTime
	self.IsPlaying = true
	table.insert(self._playSnapshots, {
		Type = "Play",
		Time = currentTime,
		LastProgress = self.ProgressTime,
	})

	self.Playing:Fire()
	updateUntilNotPlaying(self)
end

--[=[
	현재 ProgressTime 을 유지한 채 트윈을 일시정지합니다.
	`Play` 를 다시 호출하면 해당 지점부터 이어집니다.
]=]
function DynamicTween:Pause()
	if not self.IsPlaying then
		return
	end
	table.insert(self._playSnapshots, {
		Type = "Pause",
		Time = self.Timer.ElapsedTime,
		LastProgress = self.ProgressTime,
	})

	self.IsPlaying = false
end

return DynamicTween, createDynamicTween, createDynamicTweenFromInstance
