//
//  LMMediaPlayer.m
//  iPodMusicSample
//
//  Created by Akira Matsuda on 2014/01/10.
//  Copyright (c) 2014年 Akira Matsuda. All rights reserved.
//

#import "LMMediaPlayer.h"
#import "NSArray+LMMediaPlayerShuffle.h"
#import <AudioToolbox/AudioToolbox.h>

NSString *const LMMediaPlayerPauseNotification = @"LMMediaPlayerPauseNotification";
NSString *const LMMediaPlayerStopNotification = @"LMMediaPlayerStopNotification";

@interface LMMediaPlayer ()
{
	NSMutableArray *queue_;
	NSMutableArray *shffledQueue_;
	NSMutableArray *currentQueue_;
	
	AVPlayer *player_;
	
	LMMediaPlaybackState playbackState_;
	
	id playerObserver_;
}

@end

@implementation LMMediaPlayer

@synthesize player = player_;
@synthesize playbackState = playbackState_;

static LMMediaPlayer *sharedPlayer;

+ (instancetype)sharedPlayer
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sharedPlayer = [LMMediaPlayer new];
	});
	
	return sharedPlayer;
}

- (id)init
{
	self = [super init];
	if (self) {
		queue_ = [NSMutableArray new];
		currentQueue_ = queue_;
		_repeatMode = LMMediaRepeatModeNone;
		_shuffleMode = YES;
		
		static dispatch_once_t onceToken;
		dispatch_once(&onceToken, ^{
			NSError *e = nil;
			AVAudioSession *audioSession = [AVAudioSession sharedInstance];
			[audioSession setCategory:AVAudioSessionCategoryPlayback error:&e];
			NSLog(@"%@", [e description]);
			[audioSession setActive:YES error: NULL];
		});
		
		NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
		[notificationCenter addObserver:self selector:@selector(pause) name:LMMediaPlayerPauseNotification object:nil];
		[notificationCenter addObserver:self selector:@selector(stop) name:LMMediaPlayerStopNotification object:nil];
		[notificationCenter addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
	}
	
	return self;
}

- (void)dealloc
{
	NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
	[notificationCenter removeObserver:self name:LMMediaPlayerPauseNotification object:nil];
	[notificationCenter removeObserver:self name:LMMediaPlayerStopNotification object:nil];
	[notificationCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
}

- (void)pauseOtherPlayer
{
	NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
	[notificationCenter removeObserver:self name:LMMediaPlayerPauseNotification object:nil];
	[notificationCenter postNotificationName:LMMediaPlayerPauseNotification object:nil];
	[notificationCenter addObserver:self selector:@selector(pause) name:LMMediaPlayerPauseNotification object:nil];
}

- (void)stopOtherPlayer
{
	NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
	[notificationCenter removeObserver:self name:LMMediaPlayerStopNotification object:nil];
	[notificationCenter postNotificationName:LMMediaPlayerStopNotification object:nil];
	[notificationCenter addObserver:self selector:@selector(stop) name:LMMediaPlayerStopNotification object:nil];
}

- (void)awake
{
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
}

- (void)freeze
{
	[[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
}

- (void)playerItemDidReachEnd:(NSNotification *)notification
{
	[self playNextMedia];
}

- (void)addMedia:(LMMediaItem *)media
{
	[currentQueue_ addObject:media];
}

- (void)removeMediaAtIndex:(NSUInteger)index
{
	[currentQueue_ removeObjectAtIndex:index];
}

- (void)replaceMediaAtIndex:(LMMediaItem *)media index:(NSInteger)index
{
	[currentQueue_ replaceObjectAtIndex:index withObject:media];
}

- (void)removeAllMediaInQueue
{
	[currentQueue_ removeAllObjects];
}

- (void)setCurrentQueue:(NSArray *)queue
{
	for (LMMediaItem *item in queue) {
		[queue_ addObject:item];
	}
	currentQueue_ = queue_;
}

- (void)updateLockScreenInfo
{
	NSMutableDictionary *songInfo = [[NSMutableDictionary alloc] init];
	[songInfo setObject:[_nowPlayingItem getTitle] ?: @"" forKey:MPMediaItemPropertyTitle];
	[songInfo setObject:[_nowPlayingItem getAlbumTitle] ?: @"" forKey:MPMediaItemPropertyAlbumTitle];
	[songInfo setObject:[_nowPlayingItem getArtistString] ?: @"" forKey:MPMediaItemPropertyArtist];
	UIImage *artworkImage = [_nowPlayingItem getArtworkImageWithSize:CGSizeMake(320, 320)];
	if (artworkImage) {
		MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithImage:artworkImage];
		[songInfo setObject:artwork forKey:MPMediaItemPropertyArtwork];
	}
	[[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:songInfo];
}

- (void)playMedia:(LMMediaItem *)media
{
	[self stop];
	
	if ([self.delegate respondsToSelector:@selector(mediaPlayerWillStartPlaying:media:)] && [self.delegate mediaPlayerWillStartPlaying:self media:media]) {
		NSURL *url = [media getAssetURL];
		_nowPlayingItem = media;
		if (player_) {
			[player_ removeTimeObserver:playerObserver_];
			[player_ replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:url]];
		}
		else {
			player_ = [AVPlayer playerWithURL:url];
		}
		[player_ play];
		[self setCurrentState:LMMediaPlaybackStatePlaying];
		if ([self.delegate respondsToSelector:@selector(mediaPlayerDidStartPlaying:media:)]) {
			[self.delegate mediaPlayerDidStartPlaying:self media:media];
		}
		player_.usesExternalPlaybackWhileExternalScreenIsActive = YES;
		__weak LMMediaPlayer *bself = self;
		playerObserver_ = [player_ addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
			if ([bself.delegate respondsToSelector:@selector(mediaPlayerDidChangeCurrentTime:)]) {
				[bself.delegate mediaPlayerDidChangeCurrentTime:bself];
			}
		}];
	}
}

- (void)play
{
	if (_nowPlayingItem == nil) {
		[self playMedia:currentQueue_.firstObject];
	}
	else {
		[player_ play];
		[self setCurrentState:LMMediaPlaybackStatePlaying];
	}
}

- (void)playAtIndex:(NSInteger)index
{
	_index = MAX(0, MIN(index, currentQueue_.count - 1));
	[self playMedia:currentQueue_[_index]];
}

- (void)stop
{
	[player_ pause];
	[player_ seekToTime:CMTimeMake(0, 1)];
	[self setCurrentState:LMMediaPlaybackStateStopped];
	if ([self.delegate respondsToSelector:@selector(mediaPlayerDidStop:media:)]) {
		[self.delegate mediaPlayerDidStop:self media:_nowPlayingItem];
	}
	_nowPlayingItem = nil;
}

- (void)pause
{
	[player_ pause];
	[self setCurrentState:LMMediaPlaybackStatePaused];
}

- (void)playNextMedia
{
	if ([self.delegate respondsToSelector:@selector(mediaPlayerDidFinishPlaying:media:)]) {
		[self.delegate mediaPlayerDidFinishPlaying:self media:_nowPlayingItem];
	}
	if (currentQueue_.count) {
		if (_repeatMode == LMMediaRepeatModeNone) {
			if (_index >= currentQueue_.count - 1) {
				_index = 0;
				[self stop];
			}
			else {
				_index++;
				[self playMedia:currentQueue_[_index]];
			}
		}
		else if (_repeatMode == LMMediaRepeatModeAll) {
			if (_index >= currentQueue_.count - 1) {
				_index = 0;
			}
			else {
				_index++;
			}
			[self playMedia:currentQueue_[_index]];
		}
		else {
			[self playMedia:currentQueue_[_index]];
		}
	}
	else if (_repeatMode == LMMediaRepeatModeOne || _repeatMode == LMMediaRepeatModeAll){
		[self playMedia:self.nowPlayingItem];
	}
}

- (void)playPreviousMedia
{
	if ([self.delegate respondsToSelector:@selector(mediaPlayerDidFinishPlaying:media:)]) {
		[self.delegate mediaPlayerDidFinishPlaying:self media:_nowPlayingItem];
	}
	if (currentQueue_.count) {
		if (_repeatMode == LMMediaRepeatModeNone) {
			if (_index - 1 < 0) {
				_index = 0;
				[self stop];
			}
			else {
				_index--;
				[self playMedia:currentQueue_[_index]];
			}
		}
		else if (_repeatMode == LMMediaRepeatModeAll) {
			if (_index - 1 < 0) {
				_index = currentQueue_.count - 1;
			}
			else {
				_index--;
			}
			[self playMedia:currentQueue_[_index]];
		}
		else {
			[self playMedia:currentQueue_[_index]];
		}
	}
	else if (_repeatMode == LMMediaRepeatModeOne || _repeatMode == LMMediaRepeatModeAll){
		[self playMedia:self.nowPlayingItem];
	}
}

- (NSArray *)getQueue
{
	return [currentQueue_ copy];
}

- (NSUInteger)numberOfQueue
{
	return currentQueue_.count;
}

- (NSTimeInterval)currentPlaybackTime
{
	return player_.currentTime.value == 0 ? 0 : player_.currentTime.value / player_.currentTime.timescale;
}

- (NSTimeInterval)currentPlaybackDuration
{
	return CMTimeGetSeconds(player_.currentItem.duration);
}

- (void)seekTo:(NSTimeInterval)time
{
	[player_ seekToTime:CMTimeMake(time, 1)];
}

- (void)setShuffleEnabled:(BOOL)enabled
{
	_shuffleMode = enabled;
	if ([self numberOfQueue] > 0 && _shuffleMode) {
		shffledQueue_ = [[currentQueue_ shuffledArray] mutableCopy];
		currentQueue_ = shffledQueue_;
	}
	else {
		currentQueue_ = queue_;
	}
	
	if ([self.delegate respondsToSelector:@selector(mediaPlayerDidChangeShuffleEnabled:player:)]) {
		[self.delegate mediaPlayerDidChangeShuffleEnabled:enabled player:self];
	}
}

- (void)setRepeatMode:(LMMediaRepeatMode)repeatMode
{
	_repeatMode = repeatMode;
	if ([self.delegate respondsToSelector:@selector(mediaPlayerDidChangeRepeatMode:player:)]) {
		[self.delegate mediaPlayerDidChangeRepeatMode:repeatMode player:self];
	}
}

#pragma mark - private

- (void)setCurrentState:(LMMediaPlaybackState)state
{
	if ([self.delegate respondsToSelector:@selector(mediaPlayerWillChangeState:)]) {
		[self.delegate mediaPlayerWillChangeState:state];
	}
	
	[self updateLockScreenInfo];
	
	playbackState_ = state;
}

- (void)updatePlayingMusicInfo:(NSNotification *)notification
{
	if ([self.delegate respondsToSelector:@selector(mediaPlayerDidFinishPlaying:media:)]) {
		[self.delegate mediaPlayerDidFinishPlaying:self media:_nowPlayingItem];
	}
}

@end