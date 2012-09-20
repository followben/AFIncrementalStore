// AFIncrementalStore.m
//
// Copyright (c) 2012 Mattt Thompson (http://mattt.me)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFIncrementalStore.h"
#import "AFHTTPClient.h"

NSString * AFIncrementalStoreUnimplementedMethodException = @"com.alamofire.incremental-store.exceptions.unimplemented-method";

static NSString * const kAFIncrementalStoreResourceIdentifierAttributeName = @"__af_resourceIdentifier";

@interface AFIncrementalStore ()
- (NSManagedObjectContext *)backingManagedObjectContext;
- (NSManagedObjectID *)objectIDForEntity:(NSEntityDescription *)entity
                  withResourceIdentifier:(NSString *)resourceIdentifier;
- (NSManagedObjectID *)objectIDForBackingObjectForEntity:(NSEntityDescription *)entity
                                  withResourceIdentifier:(NSString *)resourceIdentifier;
- (void)createOrUpdateManagedObjectsFromArrayOfRepresentations:(NSArray *)representations
                                                      ofEntity:(NSEntityDescription *)entity
                                                  fromResponse:(NSHTTPURLResponse *)response
                                                       context:(NSManagedObjectContext *)context
                                                    completion:(void(^)())completionBlock;
@end

@implementation AFIncrementalStore {
@private
    NSCache *_propertyValuesCache;
    NSCache *_relationshipsCache;
    NSCache *_backingObjectIDByObjectID;
    NSMutableDictionary *_registeredObjectIDsByResourceIdentifier;
    NSPersistentStoreCoordinator *_backingPersistentStoreCoordinator;
    NSManagedObjectContext *_backingManagedObjectContext;
}
@synthesize HTTPClient = _HTTPClient;
@synthesize backingPersistentStoreCoordinator = _backingPersistentStoreCoordinator;

+ (NSString *)type {
    @throw([NSException exceptionWithName:AFIncrementalStoreUnimplementedMethodException reason:NSLocalizedString(@"Unimplemented method: +type. Must be overridden in a subclass", nil) userInfo:nil]);
}

+ (NSManagedObjectModel *)model {
    @throw([NSException exceptionWithName:AFIncrementalStoreUnimplementedMethodException reason:NSLocalizedString(@"Unimplemented method: +model. Must be overridden in a subclass", nil) userInfo:nil]);
}

- (BOOL)loadMetadata:(NSError *__autoreleasing *)error {
    if (!_propertyValuesCache) {
        NSMutableDictionary *mutableMetadata = [NSMutableDictionary dictionary];
        [mutableMetadata setValue:[[NSProcessInfo processInfo] globallyUniqueString] forKey:NSStoreUUIDKey];
        [mutableMetadata setValue:NSStringFromClass([self class]) forKey:NSStoreTypeKey];
        [self setMetadata:mutableMetadata];
        
        _propertyValuesCache = [[NSCache alloc] init];
        _relationshipsCache = [[NSCache alloc] init];
        _backingObjectIDByObjectID = [[NSCache alloc] init];
        _registeredObjectIDsByResourceIdentifier = [[NSMutableDictionary alloc] init];
        
        NSManagedObjectModel *model = [self.persistentStoreCoordinator.managedObjectModel copy];
        for (NSEntityDescription *entity in model.entities) {
            // Don't add resource identifier property for sub-entities, as they already exist in the super-entity 
            if ([entity superentity]) {
                continue;
            }
            
            NSAttributeDescription *resourceIdentifierProperty = [[NSAttributeDescription alloc] init];
            [resourceIdentifierProperty setName:kAFIncrementalStoreResourceIdentifierAttributeName];
            [resourceIdentifierProperty setAttributeType:NSStringAttributeType];
            [resourceIdentifierProperty setIndexed:YES];
            [entity setProperties:[entity.properties arrayByAddingObject:resourceIdentifierProperty]];
        }
        
        _backingPersistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        
        return YES;
    } else {
        return NO;
    }
}

- (NSManagedObjectContext *)backingManagedObjectContext {
    if (!_backingManagedObjectContext) {
        _backingManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        _backingManagedObjectContext.persistentStoreCoordinator = _backingPersistentStoreCoordinator;
        _backingManagedObjectContext.retainsRegisteredObjects = YES;
    }
    
    return _backingManagedObjectContext;
}

- (NSManagedObjectID *)objectIDForEntity:(NSEntityDescription *)entity
                  withResourceIdentifier:(NSString *)resourceIdentifier {
    NSManagedObjectID *objectID = [_registeredObjectIDsByResourceIdentifier objectForKey:resourceIdentifier];
    if (objectID == nil) {
        objectID = [self newObjectIDForEntity:entity referenceObject:resourceIdentifier];
    }
    
    return objectID;
}

- (NSManagedObjectID *)objectIDForBackingObjectForEntity:(NSEntityDescription *)entity
                                  withResourceIdentifier:(NSString *)resourceIdentifier
{
    if (!resourceIdentifier) {
        return nil;
    }
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:[entity name]];
    fetchRequest.resultType = NSManagedObjectIDResultType;
    fetchRequest.fetchLimit = 1;
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K = %@", kAFIncrementalStoreResourceIdentifierAttributeName, resourceIdentifier];
    
    __block NSError *error = nil;
    __block NSArray *results = [NSArray array];
    [[self backingManagedObjectContext] performBlock:^{
        results = [[self backingManagedObjectContext] executeFetchRequest:fetchRequest error:&error];
    }];
    if (error) {
        NSLog(@"Error: %@", error);
        return nil;
    }
    
    return [results lastObject];
}

- (NSManagedObject *)findOrCreateBackingObjectWithResourceIdentifier:(NSString *)resourceIdentifier
                                                            ofEntity:(NSEntityDescription *)entity
                                                          attributes:(NSDictionary *)attributes
                                                      backingContext:(NSManagedObjectContext *)backingContext
                                                        childContext:(NSManagedObjectContext *)childContext
                                                            objectID:(NSManagedObjectID *)objectID

{
    
    NSManagedObject *backingObject = (objectID != nil) ? [backingContext existingObjectWithID:objectID error:nil] : [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:backingContext];
    [backingObject setValue:resourceIdentifier forKey:kAFIncrementalStoreResourceIdentifierAttributeName];
    [backingObject setValuesForKeysWithDictionary:attributes];
    
    return backingObject;
}

- (NSManagedObject *)findAndUpdateObjectWithResourceIdentifier:(NSString *)resourceIdentifier
                                                      ofEntity:(NSEntityDescription *)entity
                                                    attributes:(NSDictionary *)attributes
                                                backingContext:(NSManagedObjectContext *)backingContext
                                                  childContext:(NSManagedObjectContext *)childContext
                                                      objectID:(NSManagedObjectID *)objectID

{
    NSManagedObject *managedObject = [childContext existingObjectWithID:[self objectIDForEntity:entity withResourceIdentifier:resourceIdentifier] error:nil];
    [managedObject setValuesForKeysWithDictionary:attributes];
    if (objectID == nil) {
        [childContext insertObject:managedObject];
    }
    
    return managedObject;
}

- (void)attributesForRepresentation:(NSDictionary *)representation
                           ofEntity:(NSEntityDescription *)entity
                       fromResponse:(NSHTTPURLResponse *)response
                        completion:(void (^)(NSString *resourceIdentifier, NSDictionary *attributes, NSDictionary *relationshipRepresentations))completionBlock {
    
    NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation ofEntity:entity fromResponse:response];
    NSDictionary *attributes = [self.HTTPClient attributesForRepresentation:representation ofEntity:entity fromResponse:response];
    NSDictionary *relationshipRepresentations = [self.HTTPClient representationsForRelationshipsFromRepresentation:representation ofEntity:entity fromResponse:response];
    
    completionBlock(resourceIdentifier, attributes, relationshipRepresentations);
    
}

- (void)createOrUpdateRelationshipsFromRepresentations:(NSDictionary *)relationshipRepresentations
                                             forEntity:(NSEntityDescription *)entity
                                          fromResponse:(NSHTTPURLResponse *)response
                                        backingContext:(NSManagedObjectContext *)backingContext
                                          childContext:(NSManagedObjectContext *)childContext
                                         backingObject:(NSManagedObject *)backingObject
                                         managedObject:(NSManagedObject *)managedObject
{
    
    for (NSString *relationshipName in relationshipRepresentations) {
        id relationshipRepresentationOrArrayOfRepresentations = [relationshipRepresentations objectForKey:relationshipName];
        NSRelationshipDescription *relationship = [[entity relationshipsByName] valueForKey:relationshipName];
        
        if (relationship) {
            if ([relationship isToMany]) {
                id mutableManagedRelationshipObjects = [relationship isOrdered] ? [NSMutableOrderedSet orderedSet] : [NSMutableSet set];
                id mutableBackingRelationshipObjects = [relationship isOrdered] ? [NSMutableOrderedSet orderedSet] : [NSMutableSet set];
                
                for (NSDictionary *relationshipRepresentation in relationshipRepresentationOrArrayOfRepresentations) {
                    NSEntityDescription *destinationEntity = [self.HTTPClient entityForRepresentation:relationshipRepresentation ofEntity:relationship.destinationEntity fromResponse:response];
                    [self attributesForRepresentation:relationshipRepresentation ofEntity:destinationEntity fromResponse:response completion:^(NSString *theResourceIdentifier, NSDictionary *attributes, NSDictionary *relationshipRepresentations) {
                        
                        NSManagedObjectID *relationshipObjectID = [self objectIDForBackingObjectForEntity:destinationEntity withResourceIdentifier:theResourceIdentifier];
                        
                        NSManagedObject *backingRelationshipObject = [self findOrCreateBackingObjectWithResourceIdentifier:theResourceIdentifier ofEntity:destinationEntity attributes:attributes backingContext:backingContext childContext:childContext objectID:relationshipObjectID];
                        
                        [mutableBackingRelationshipObjects addObject:backingRelationshipObject];
                        
                        NSManagedObject *managedRelationshipObject = [self findAndUpdateObjectWithResourceIdentifier:theResourceIdentifier ofEntity:destinationEntity attributes:attributes backingContext:backingContext childContext:childContext objectID:relationshipObjectID];
                        
                        [mutableManagedRelationshipObjects addObject:managedRelationshipObject];
                        
                        [self createOrUpdateRelationshipsFromRepresentations:relationshipRepresentations forEntity:destinationEntity fromResponse:response backingContext:backingContext childContext:childContext backingObject:backingRelationshipObject managedObject:managedRelationshipObject];
                        
                        
                    }];
                    
                }
                
                [backingObject setValue:mutableBackingRelationshipObjects forKey:relationship.name];
                [managedObject setValue:mutableManagedRelationshipObjects forKey:relationship.name];
                
            } else {
                NSEntityDescription *destinationEntity = [self.HTTPClient entityForRepresentation:relationshipRepresentationOrArrayOfRepresentations ofEntity:relationship.destinationEntity fromResponse:response];
                [self attributesForRepresentation:relationshipRepresentationOrArrayOfRepresentations ofEntity:destinationEntity fromResponse:response completion:^(NSString *theResourceIdentifier, NSDictionary *theAttributes, NSDictionary *relationshipRepresentations) {
                    
                    NSManagedObjectID *relationshipObjectID = [self objectIDForBackingObjectForEntity:destinationEntity withResourceIdentifier:theResourceIdentifier];
                    
                    NSManagedObject *backingRelationshipObject = [self findOrCreateBackingObjectWithResourceIdentifier:theResourceIdentifier ofEntity:destinationEntity attributes:theAttributes backingContext:backingContext childContext:childContext objectID:relationshipObjectID];
                    
                    [backingObject setValue:backingRelationshipObject forKey:relationship.name];
                    
                    NSManagedObject *managedRelationshipObject = [self findAndUpdateObjectWithResourceIdentifier:theResourceIdentifier ofEntity:destinationEntity attributes:theAttributes backingContext:backingContext childContext:childContext objectID:relationshipObjectID];
                    
                    [managedObject setValue:managedRelationshipObject forKey:relationship.name];
                    
                    [self createOrUpdateRelationshipsFromRepresentations:relationshipRepresentations forEntity:destinationEntity fromResponse:response backingContext:backingContext childContext:childContext backingObject:backingRelationshipObject managedObject:managedRelationshipObject];
                    
                    
                }];
            }
        }
    }
    
    
}

- (void)createOrUpdateManagedObjectsFromRepresentation:(NSDictionary *)representation
                                              ofEntity:(NSEntityDescription *)entity
                                          fromResponse:(NSHTTPURLResponse *)response
                                               context:(NSManagedObjectContext *)context
{
    NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
    [self attributesForRepresentation:representation ofEntity:entity fromResponse:response completion:^(NSString *resourceIdentifier, NSDictionary *attributes, NSDictionary *relationshipRepresentations) {
        
        NSManagedObjectID *objectID = [self objectIDForBackingObjectForEntity:entity withResourceIdentifier:resourceIdentifier];
        
        NSManagedObject *backingObject = [self findOrCreateBackingObjectWithResourceIdentifier:resourceIdentifier ofEntity:entity attributes:attributes backingContext:backingContext childContext:context objectID:objectID];
        
        NSManagedObject *managedObject = [self findAndUpdateObjectWithResourceIdentifier:resourceIdentifier ofEntity:entity attributes:attributes backingContext:backingContext childContext:context objectID:objectID];
        
        [self createOrUpdateRelationshipsFromRepresentations:relationshipRepresentations forEntity:entity fromResponse:response backingContext:backingContext childContext:context backingObject:backingObject managedObject:managedObject];
        
    }];
    
}


- (void)createOrUpdateManagedObjectsFromArrayOfRepresentations:(NSArray *)representations
                                                      ofEntity:(NSEntityDescription *)entity
                                                  fromResponse:(NSHTTPURLResponse *)response
                                                       context:(NSManagedObjectContext *)context
                                                    completion:(void(^)())completionBlock
{
    NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
    [context performBlock:^{
        for (NSDictionary *representation in representations) {
            [self createOrUpdateManagedObjectsFromRepresentation:representation ofEntity:entity fromResponse:response context:context];
        }
        
        [backingContext performBlock:^{
            NSError *error = nil;
            if (![backingContext save:&error]) {
                NSLog(@"Error: %@", error);
            } else {
                [context performBlock:^{
                    NSError *error = nil;
                    if (![context save:&error]) {
                        NSLog(@"Error: %@", error);
                    } else if (completionBlock) {
                        completionBlock();
                    }
                }];
            }
            
        }];

    }];

}

#pragma mark -

- (id)executeRequest:(NSPersistentStoreRequest *)persistentStoreRequest
         withContext:(NSManagedObjectContext *)context
               error:(NSError *__autoreleasing *)error
{
    if (persistentStoreRequest.requestType == NSFetchRequestType) {
        NSFetchRequest *fetchRequest = (NSFetchRequest *)persistentStoreRequest;
        
        NSURLRequest *request = [self.HTTPClient requestForFetchRequest:fetchRequest withContext:context];
        if ([request URL]) {
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsFromResponseObject:responseObject];
                
                NSArray *representations = nil;
                if ([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]]) {
                    representations = representationOrArrayOfRepresentations;
                } else {
                    representations = [NSArray arrayWithObject:representationOrArrayOfRepresentations];
                }
                
                NSManagedObjectContext *childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
                childContext.parentContext = context;
                childContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
                
                [[NSNotificationCenter defaultCenter] addObserverForName:NSManagedObjectContextDidSaveNotification object:childContext queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                    [context mergeChangesFromContextDidSaveNotification:note];
                }];
                
                [self createOrUpdateManagedObjectsFromArrayOfRepresentations:representations
                                                                    ofEntity:fetchRequest.entity
                                                                fromResponse:operation.response
                                                                     context:childContext
                                                                  completion:nil];
                
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Error: %@", error);
            }];
            
            operation.successCallbackQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
            [self.HTTPClient enqueueHTTPRequestOperation:operation];
        }
        
        NSManagedObjectContext *backingContext = [self backingManagedObjectContext];
        NSArray *results = nil;
        
        NSFetchRequestResultType resultType = fetchRequest.resultType;
        switch (resultType) {
            case NSManagedObjectResultType: {
                fetchRequest = [fetchRequest copy];
                fetchRequest.entity = [NSEntityDescription entityForName:fetchRequest.entityName inManagedObjectContext:backingContext];
                fetchRequest.resultType = NSDictionaryResultType;
                fetchRequest.propertiesToFetch = @[ kAFIncrementalStoreResourceIdentifierAttributeName ];
                results = [backingContext executeFetchRequest:fetchRequest error:error];
                NSMutableArray *mutableObjects = [NSMutableArray arrayWithCapacity:[results count]];
                for (NSString *resourceIdentifier in [results valueForKeyPath:kAFIncrementalStoreResourceIdentifierAttributeName]) {
                    NSManagedObjectID *objectID = [self objectIDForEntity:fetchRequest.entity withResourceIdentifier:resourceIdentifier];
                    NSManagedObject *object = [context objectWithID:objectID];
                    [mutableObjects addObject:object];
                }
                
                return mutableObjects;
            }
            case NSManagedObjectIDResultType:
            case NSDictionaryResultType:
            case NSCountResultType:
                return [backingContext executeFetchRequest:fetchRequest error:error];
            default:
                goto _error;
        }
    } else {
        switch (persistentStoreRequest.requestType) {
            case NSSaveRequestType:
                return @[];
            default:
                goto _error;
        }
    }
    
    return nil;
    
    _error: {
        NSMutableDictionary *mutableUserInfo = [NSMutableDictionary dictionary];
        [mutableUserInfo setValue:[NSString stringWithFormat:NSLocalizedString(@"Unsupported NSFetchRequestResultType, %d", nil), persistentStoreRequest.requestType] forKey:NSLocalizedDescriptionKey];
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFNetworkingErrorDomain code:0 userInfo:mutableUserInfo];
        }
        
        return nil;
    }
}

- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError *__autoreleasing *)error
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:[[objectID entity] name]];
    fetchRequest.resultType = NSDictionaryResultType;
    fetchRequest.fetchLimit = 1;
    fetchRequest.includesSubentities = NO;
    fetchRequest.propertiesToFetch = [[[NSEntityDescription entityForName:fetchRequest.entityName inManagedObjectContext:context] attributesByName] allKeys];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K = %@", kAFIncrementalStoreResourceIdentifierAttributeName, [self referenceObjectForObjectID:objectID]];
    
    NSArray *results = [[self backingManagedObjectContext] executeFetchRequest:fetchRequest error:error];
    NSDictionary *attributeValues = [results lastObject] ?: [NSDictionary dictionary];

    NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:attributeValues version:1];
    
    if ([self.HTTPClient respondsToSelector:@selector(shouldFetchRemoteAttributeValuesForObjectWithID:inManagedObjectContext:)] && [self.HTTPClient shouldFetchRemoteAttributeValuesForObjectWithID:objectID inManagedObjectContext:context]) {
        if (attributeValues) {
            
            NSURLRequest *request = [self.HTTPClient requestWithMethod:@"GET" pathForObjectWithID:objectID withContext:context];
            
            if ([request URL]) {
                AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, NSDictionary *representation) {                    
                                        
                    NSManagedObjectContext *childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
                    childContext.parentContext = context;
                    childContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
                    
                    [self createOrUpdateManagedObjectsFromArrayOfRepresentations:@[representation]
                                                                        ofEntity:objectID.entity
                                                                    fromResponse:operation.response
                                                                         context:childContext
                                                                      completion:^{
                                                                          [context performBlock:^{
                                                                              NSError *error = nil;
                                                                              if (![context save:&error]) {
                                                                                  NSLog(@"Error: %@", error);
                                                                              }
                                                                          }];
                                                                      }];
                    
                } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                    NSLog(@"Error: %@, %@", operation, error);
                }];
                
                [self.HTTPClient enqueueHTTPRequestOperation:operation];
            }
        }
    }
    
    return node;
}

- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError *__autoreleasing *)error
{
    if ([self.HTTPClient respondsToSelector:@selector(shouldFetchRemoteValuesForRelationship:forObjectWithID:inManagedObjectContext:)] && [self.HTTPClient shouldFetchRemoteValuesForRelationship:relationship forObjectWithID:objectID inManagedObjectContext:context]) {
        NSURLRequest *request = [self.HTTPClient requestWithMethod:@"GET" pathForRelationship:relationship forObjectWithID:objectID withContext:context];
        
        if ([request URL] && ![[context existingObjectWithID:objectID error:nil] hasChanges]) {
            NSManagedObjectContext *childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
            childContext.parentContext = context;
            childContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
            
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsFromResponseObject:responseObject];
                
                NSArray *representations = nil;
                if ([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]]) {
                    representations = representationOrArrayOfRepresentations;
                } else {
                    representations = [NSArray arrayWithObject:representationOrArrayOfRepresentations];
                }
                
                [self createOrUpdateManagedObjectsFromArrayOfRepresentations:representations
                                                                    ofEntity:objectID.entity
                                                                fromResponse:operation.response
                                                                     context:childContext
                                                                  completion:nil];
                
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Error: %@, %@", operation, error);
            }];
            
            operation.successCallbackQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
            [self.HTTPClient enqueueHTTPRequestOperation:operation];
        }
    }
    
    NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[objectID entity] withResourceIdentifier:[self referenceObjectForObjectID:objectID]];
    NSManagedObject *backingObject = (backingObjectID == nil) ? nil : [[self backingManagedObjectContext] existingObjectWithID:backingObjectID error:nil];
    
    if (backingObject && ![backingObject hasChanges]) {
        id backingRelationshipObject = [backingObject valueForKeyPath:relationship.name];
        if ([relationship isToMany]) {
            NSMutableArray *mutableObjects = [NSMutableArray arrayWithCapacity:[backingRelationshipObject count]];
            for (NSString *resourceIdentifier in [backingRelationshipObject valueForKeyPath:kAFIncrementalStoreResourceIdentifierAttributeName]) {
                NSManagedObjectID *objectID = [self objectIDForEntity:relationship.destinationEntity withResourceIdentifier:resourceIdentifier];
                [mutableObjects addObject:objectID];
            }
                        
            return mutableObjects;            
        } else {
            NSString *resourceIdentifier = [backingRelationshipObject valueForKeyPath:kAFIncrementalStoreResourceIdentifierAttributeName];
            NSManagedObjectID *objectID = [self objectIDForEntity:relationship.destinationEntity withResourceIdentifier:resourceIdentifier];
            return objectID ?: [NSNull null];
        }
    } else {
        if ([relationship isToMany]) {
            return [NSArray array];
        } else {
            return [NSNull null];
        }
    }
}

#pragma mark - NSIncrementalStore

- (void)managedObjectContextDidRegisterObjectsWithIDs:(NSArray *)objectIDs {
    [super managedObjectContextDidRegisterObjectsWithIDs:objectIDs];
    for (NSManagedObjectID *objectID in objectIDs) {
        [_registeredObjectIDsByResourceIdentifier setObject:objectID forKey:[self referenceObjectForObjectID:objectID]];
    }
}

- (void)managedObjectContextDidUnregisterObjectsWithIDs:(NSArray *)objectIDs {
    [super managedObjectContextDidUnregisterObjectsWithIDs:objectIDs];
    for (NSManagedObjectID *objectID in objectIDs) {
        [_registeredObjectIDsByResourceIdentifier removeObjectForKey:[self referenceObjectForObjectID:objectID]];
    }    
}

@end
