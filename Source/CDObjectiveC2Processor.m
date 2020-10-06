// -*- mode: ObjC -*-

/********************************************
  Copyright 2018 PreEmptive Solutions, LLC
  See LICENSE.txt for licensing information
********************************************/

//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 1997-1998, 2000-2001, 2004-2015 Steve Nygard.

#import "CDObjectiveC2Processor.h"

#import "CDMachOFile.h"
#import "CDSection.h"
#import "CDLCSegment.h"
#import "CDMachOFileDataCursor.h"
#import "CDOCClass.h"
#import "CDOCMethod.h"
#import "CDOCInstanceVariable.h"
#import "CDLCSymbolTable.h"
#import "CDOCCategory.h"
#import "CDClassDump.h"
#import "CDSymbol.h"
#import "CDOCProperty.h"
#import "cd_objc2.h"
#import "CDProtocolUniquer.h"
#import "CDOCClassReference.h"

@implementation CDObjectiveC2Processor
{
}

- (void)loadProtocols;
{
    CDSection *section = [[self.machOFile dataConstSegment] sectionWithName:@"__objc_protolist"];
    
    CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithSection:section];
    while ([cursor isAtEnd] == NO)
        [self protocolAtAddress:[cursor readPtr]];
}

- (int)loadClasses;
{
    CDSection *section = [[self.machOFile dataConstSegment] sectionWithName:@"__objc_classlist"];
    
    CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithSection:section];
    while ([cursor isAtEnd] == NO) {
        uint64_t val = [cursor readPtr];
        CDOCClass *aClass = [self loadClassAtAddress:val];
        if (aClass != nil) {
            if (aClass.isSwiftClass) {
                NSLog(@"Error: PPiOS-Rename cannot process apps containing Swift code: %@", aClass.name);
                return 1;
            }
            [self addClass:aClass withAddress:val];
        }
    }

    return 0;
}

- (void)loadCategories;
{
    CDSection *section = [[self.machOFile dataConstSegment] sectionWithName:@"__objc_catlist"];
    
    CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithSection:section];
    while ([cursor isAtEnd] == NO) {
        CDOCCategory *category = [self loadCategoryAtAddress:[cursor readPtr]];
        [self addCategory:category];
    }
}

- (CDOCProtocol *)protocolAtAddress:(uint64_t)address;
{
    if (address == 0)
        return nil;
    
    CDOCProtocol *protocol = [self.protocolUniquer protocolWithAddress:address];
    if (protocol == nil) {
        protocol = [[CDOCProtocol alloc] init];
        [self.protocolUniquer setProtocol:protocol withAddress:address];
        
        CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:address];
        NSParameterAssert([cursor offset] != 0);
        
        struct cd_objc2_protocol objc2Protocol;
        objc2Protocol.isa                     = [cursor readPtr];
        objc2Protocol.name                    = [cursor readPtr];
        objc2Protocol.protocols               = [cursor readPtr];
        objc2Protocol.instanceMethods         = [cursor readPtr];
        objc2Protocol.classMethods            = [cursor readPtr];
        objc2Protocol.optionalInstanceMethods = [cursor readPtr];
        objc2Protocol.optionalClassMethods    = [cursor readPtr];
        objc2Protocol.instanceProperties      = [cursor readPtr];
        objc2Protocol.size                    = [cursor readInt32];
        objc2Protocol.flags                   = [cursor readInt32];
        objc2Protocol.extendedMethodTypes     = 0;
        
        CDMachOFileDataCursor *extendedMethodTypesCursor = nil;
        BOOL hasExtendedMethodTypesField = objc2Protocol.size > 8 * [self.machOFile ptrSize] + 2 * sizeof(uint32_t);
        if (hasExtendedMethodTypesField) {
            objc2Protocol.extendedMethodTypes = [cursor readPtr];
            if (objc2Protocol.extendedMethodTypes != 0) {
                extendedMethodTypesCursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:objc2Protocol.extendedMethodTypes];
                NSParameterAssert([extendedMethodTypesCursor offset] != 0);
            }
        }
        
        //NSLog(@"----------------------------------------");
        //NSLog(@"%016lx %016lx %016lx %016lx", objc2Protocol.isa, objc2Protocol.name, objc2Protocol.protocols, objc2Protocol.instanceMethods);
        //NSLog(@"%016lx %016lx %016lx %016lx", objc2Protocol.classMethods, objc2Protocol.optionalInstanceMethods, objc2Protocol.optionalClassMethods, objc2Protocol.instanceProperties);
        
        NSString *str = [self.machOFile stringAtAddress:objc2Protocol.name];
        [protocol setName:str];
        
        if (objc2Protocol.protocols != 0) {
            [cursor setAddress:objc2Protocol.protocols];
            uint64_t count = [cursor readPtr];
            for (uint64_t index = 0; index < count; index++) {
                uint64_t val = [cursor readPtr];
                CDOCProtocol *anotherProtocol = [self protocolAtAddress:val];
                if (anotherProtocol != nil) {
                    [protocol addProtocol:anotherProtocol];
                } else {
                    NSLog(@"Note: another protocol was nil.");
                }
            }
        }
        
        for (CDOCMethod *method in [self loadMethodsAtAddress:objc2Protocol.instanceMethods extendedMethodTypesCursor:extendedMethodTypesCursor])
            [protocol addInstanceMethod:method];
        
        for (CDOCMethod *method in [self loadMethodsAtAddress:objc2Protocol.classMethods extendedMethodTypesCursor:extendedMethodTypesCursor])
            [protocol addClassMethod:method];
        
        for (CDOCMethod *method in [self loadMethodsAtAddress:objc2Protocol.optionalInstanceMethods extendedMethodTypesCursor:extendedMethodTypesCursor])
            [protocol addOptionalInstanceMethod:method];
        
        for (CDOCMethod *method in [self loadMethodsAtAddress:objc2Protocol.optionalClassMethods extendedMethodTypesCursor:extendedMethodTypesCursor])
            [protocol addOptionalClassMethod:method];
        
        for (CDOCProperty *property in [self loadPropertiesAtAddress:objc2Protocol.instanceProperties])
            [protocol addProperty:property];
    }
    
    return protocol;
}

- (CDOCCategory *)loadCategoryAtAddress:(uint64_t)address;
{
    if (address == 0)
        return nil;
    
    CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:address];
    NSParameterAssert([cursor offset] != 0);
    
    struct cd_objc2_category objc2Category;
    objc2Category.name               = [cursor readPtr];
    objc2Category.class              = [cursor readPtr];
    objc2Category.instanceMethods    = [cursor readPtr];
    objc2Category.classMethods       = [cursor readPtr];
    objc2Category.protocols          = [cursor readPtr];
    objc2Category.instanceProperties = [cursor readPtr];
    objc2Category.v7                 = [cursor readPtr];
    objc2Category.v8                 = [cursor readPtr];
    //NSLog(@"----------------------------------------");
    //NSLog(@"%016lx %016lx %016lx %016lx", objc2Category.name, objc2Category.class, objc2Category.instanceMethods, objc2Category.classMethods);
    //NSLog(@"%016lx %016lx %016lx %016lx", objc2Category.protocols, objc2Category.instanceProperties, objc2Category.v7, objc2Category.v8);
    
    CDOCCategory *category = [[CDOCCategory alloc] init];
    NSString *str = [self.machOFile stringAtAddress:objc2Category.name];
    [category setName:str];
    
    for (CDOCMethod *method in [self loadMethodsAtAddress:objc2Category.instanceMethods])
        [category addInstanceMethod:method];
    
    for (CDOCMethod *method in [self loadMethodsAtAddress:objc2Category.classMethods])
        [category addClassMethod:method];

    for (CDOCProtocol *protocol in [self.protocolUniquer uniqueProtocolsAtAddresses:[self protocolAddressListAtAddress:objc2Category.protocols]])
        [category addProtocol:protocol];
    
    for (CDOCProperty *property in [self loadPropertiesAtAddress:objc2Category.instanceProperties])
        [category addProperty:property];
    
    {
        uint64_t classNameAddress = address + [self.machOFile ptrSize];
        
        NSString *externalClassName = nil;
        if ([self.machOFile hasRelocationEntryForAddress2:classNameAddress]) {
            externalClassName = [self.machOFile externalClassNameForAddress2:classNameAddress];
            //NSLog(@"category: got external class name (2): %@", [category className]);
        } else if ([self.machOFile hasRelocationEntryForAddress:classNameAddress]) {
            externalClassName = [self.machOFile externalClassNameForAddress:classNameAddress];
            //NSLog(@"category: got external class name (1): %@", [aClass className]);
        } else if (objc2Category.class != 0) {
            CDOCClass *aClass = [self classWithAddress:objc2Category.class];
            category.classRef = [[CDOCClassReference alloc] initWithClassObject:aClass];
        }
        
        if (externalClassName != nil) {
            CDSymbol *classSymbol = [[self.machOFile symbolTable] symbolForExternalClassName:externalClassName];
            if (classSymbol != nil)
                category.classRef = [[CDOCClassReference alloc] initWithClassSymbol:classSymbol];
            else
                category.classRef = [[CDOCClassReference alloc] initWithClassName:externalClassName];
        }
    }
    
    return category;
}

- (CDOCClass *)loadClassAtAddress:(uint64_t)address;
{
    if (address == 0)
        return nil;
    
    CDOCClass *class = [self classWithAddress:address];
    if (class)
        return class;
    
    //NSLog(@"%s, address=%016lx", __cmd, address);
    
    CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:address];
    NSParameterAssert([cursor offset] != 0);
    
    struct cd_objc2_class objc2Class;
    objc2Class.isa        = [cursor readPtr];
    objc2Class.superclass = [cursor readPtr];
    objc2Class.cache      = [cursor readPtr];
    objc2Class.vtable     = [cursor readPtr];

    uint64_t value        = [cursor readPtr];
    BOOL isSwiftClass = (value & 0x1) != 0;
    objc2Class.data       = value & ~7;

    objc2Class.reserved1  = [cursor readPtr];
    objc2Class.reserved2  = [cursor readPtr];
    objc2Class.reserved3  = [cursor readPtr];
    //NSLog(@"%016lx %016lx %016lx %016lx", objc2Class.isa, objc2Class.superclass, objc2Class.cache, objc2Class.vtable);
    //NSLog(@"%016lx %016lx %016lx %016lx", objc2Class.data, objc2Class.reserved1, objc2Class.reserved2, objc2Class.reserved3);
    
    NSParameterAssert(objc2Class.data != 0);
    [cursor setAddress:objc2Class.data];

    struct cd_objc2_class_ro_t objc2ClassData;
    objc2ClassData.flags         = [cursor readInt32];
    objc2ClassData.instanceStart = [cursor readInt32];
    objc2ClassData.instanceSize  = [cursor readInt32];
    if ([self.machOFile uses64BitABI])
        objc2ClassData.reserved  = [cursor readInt32];
    else
        objc2ClassData.reserved = 0;
    
    objc2ClassData.ivarLayout     = [cursor readPtr];
    objc2ClassData.name           = [cursor readPtr];
    objc2ClassData.baseMethods    = [cursor readPtr];
    objc2ClassData.baseProtocols  = [cursor readPtr];
    objc2ClassData.ivars          = [cursor readPtr];
    objc2ClassData.weakIvarLayout = [cursor readPtr];
    objc2ClassData.baseProperties = [cursor readPtr];
    
    //NSLog(@"%08x %08x %08x %08x", objc2ClassData.flags, objc2ClassData.instanceStart, objc2ClassData.instanceSize, objc2ClassData.reserved);
    
    //NSLog(@"%016lx %016lx %016lx %016lx", objc2ClassData.ivarLayout, objc2ClassData.name, objc2ClassData.baseMethods, objc2ClassData.baseProtocols);
    //NSLog(@"%016lx %016lx %016lx %016lx", objc2ClassData.ivars, objc2ClassData.weakIvarLayout, objc2ClassData.baseProperties);
    NSString *str = [self.machOFile stringAtAddress:objc2ClassData.name];
    //NSLog(@"name = %@", str);
    
    CDOCClass *aClass = [[CDOCClass alloc] init];
    [aClass setName:str];
    aClass.isSwiftClass = isSwiftClass;
    
    for (CDOCMethod *method in [self loadMethodsAtAddress:objc2ClassData.baseMethods])
        [aClass addInstanceMethod:method];
    
    aClass.instanceVariables = [self loadIvarsAtAddress:objc2ClassData.ivars];
    
    {
        CDSymbol *classSymbol = [[self.machOFile symbolTable] symbolForClassName:str];
        
        if (classSymbol != nil)
            aClass.isExported = [classSymbol isExternal];
    }
    
    {
        uint64_t classNameAddress = address + [self.machOFile ptrSize];
        
        NSString *superClassName = nil;
        if ([self.machOFile hasRelocationEntryForAddress2:classNameAddress]) {
            superClassName = [self.machOFile externalClassNameForAddress2:classNameAddress];
            //NSLog(@"class: got external class name (2): %@", [aClass superClassName]);
        } else if ([self.machOFile hasRelocationEntryForAddress:classNameAddress]) {
            superClassName = [self.machOFile externalClassNameForAddress:classNameAddress];
            //NSLog(@"class: got external class name (1): %@", [aClass superClassName]);
        } else if (objc2Class.superclass != 0) {
            CDOCClass *sc = [self loadClassAtAddress:objc2Class.superclass];
            aClass.superClassRef = [[CDOCClassReference alloc] initWithClassObject:sc];
        }
        
        if (superClassName) {
            CDSymbol *superClassSymbol = [[self.machOFile symbolTable] symbolForExternalClassName:superClassName];
            if (superClassSymbol)
                aClass.superClassRef = [[CDOCClassReference alloc] initWithClassSymbol:superClassSymbol];
            else
                aClass.superClassRef = [[CDOCClassReference alloc] initWithClassName:superClassName];
        }
    }
    
    for (CDOCMethod *method in [self loadMethodsOfMetaClassAtAddress:objc2Class.isa])
        [aClass addClassMethod:method];
    
    // Process protocols
    for (CDOCProtocol *protocol in [self.protocolUniquer uniqueProtocolsAtAddresses:[self protocolAddressListAtAddress:objc2ClassData.baseProtocols]])
        [aClass addProtocol:protocol];
    
    for (CDOCProperty *property in [self loadPropertiesAtAddress:objc2ClassData.baseProperties])
        [aClass addProperty:property];
    
    return aClass;
}

- (NSArray *)loadPropertiesAtAddress:(uint64_t)address;
{
    NSMutableArray *properties = [NSMutableArray array];
    if (address != 0) {
        struct cd_objc2_list_header listHeader;
        
        CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:address];
        NSParameterAssert([cursor offset] != 0);
        //NSLog(@"property list data offset: %lu", [cursor offset]);
        
        listHeader.entsize = [cursor readInt32];
        listHeader.count = [cursor readInt32];
        NSParameterAssert(listHeader.entsize == 2 * [self.machOFile ptrSize]);
        
        for (uint32_t index = 0; index < listHeader.count; index++) {
            struct cd_objc2_property objc2Property;
            
            objc2Property.name = [cursor readPtr];
            objc2Property.attributes = [cursor readPtr];
            NSString *name = [self.machOFile stringAtAddress:objc2Property.name];
            NSString *attributes = [self.machOFile stringAtAddress:objc2Property.attributes];
            
            CDOCProperty *property = [[CDOCProperty alloc] initWithName:name attributes:attributes];
            [properties addObject:property];
        }
    }
    
    return properties;
}

// This just gets the methods.
- (NSArray *)loadMethodsOfMetaClassAtAddress:(uint64_t)address;
{
    if (address == 0)
        return nil;
    
    CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:address];
    NSParameterAssert([cursor offset] != 0);
    
    struct cd_objc2_class objc2Class;
    objc2Class.isa        = [cursor readPtr];
    objc2Class.superclass = [cursor readPtr];
    objc2Class.cache      = [cursor readPtr];
    objc2Class.vtable     = [cursor readPtr];
    objc2Class.data       = [cursor readPtr];
    objc2Class.reserved1  = [cursor readPtr];
    objc2Class.reserved2  = [cursor readPtr];
    objc2Class.reserved3  = [cursor readPtr];
    //NSLog(@"%016lx %016lx %016lx %016lx", objc2Class.isa, objc2Class.superclass, objc2Class.cache, objc2Class.vtable);
    //NSLog(@"%016lx %016lx %016lx %016lx", objc2Class.data, objc2Class.reserved1, objc2Class.reserved2, objc2Class.reserved3);
    
    NSParameterAssert(objc2Class.data != 0);
    [cursor setAddress:objc2Class.data];

    struct cd_objc2_class_ro_t objc2ClassData;
    objc2ClassData.flags         = [cursor readInt32];
    objc2ClassData.instanceStart = [cursor readInt32];
    objc2ClassData.instanceSize  = [cursor readInt32];
    if ([self.machOFile uses64BitABI])
        objc2ClassData.reserved  = [cursor readInt32];
    else
        objc2ClassData.reserved = 0;
    
    objc2ClassData.ivarLayout     = [cursor readPtr];
    objc2ClassData.name           = [cursor readPtr];
    objc2ClassData.baseMethods    = [cursor readPtr];
    objc2ClassData.baseProtocols  = [cursor readPtr];
    objc2ClassData.ivars          = [cursor readPtr];
    objc2ClassData.weakIvarLayout = [cursor readPtr];
    objc2ClassData.baseProperties = [cursor readPtr];
    
    return [self loadMethodsAtAddress:objc2ClassData.baseMethods];
}

- (NSArray *)loadMethodsAtAddress:(uint64_t)address;
{
    return [self loadMethodsAtAddress:address extendedMethodTypesCursor:nil];
}

- (NSArray *)loadMethodsAtAddress:(uint64_t)address extendedMethodTypesCursor:(CDMachOFileDataCursor *)extendedMethodTypesCursor;
{
    NSMutableArray *methods = [NSMutableArray array];
    
    if (address != 0) {
        CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:address];
        NSParameterAssert([cursor offset] != 0);
        //NSLog(@"method list data offset: %lu", [cursor offset]);
        
        struct cd_objc2_list_header listHeader;
        
        // See https://opensource.apple.com/source/objc4/objc4-787.1/runtime/objc-runtime-new.h
        uint32_t mask = 0xFFFF0003;
        uint32_t value = [cursor readInt32];
        listHeader.entsize = value & ~mask;
        uint32_t flags = value & mask;
        int smallMethods = (flags & 0x80000000) != 0;
        /*
          Tests show no leftovers were present. Consistent with comments indicating smallMethodListFlag is currently the only flag.
        int leftOvers = flags & ~0x80000000;
        if (leftOvers != 0) {
            NSLog(@"Leftovers was non-zero: 0x%08x (0x%08x)", leftOvers, value);
        }
         */
        listHeader.count = [cursor readInt32];
//        NSLog(@"Info: %u == %lu?: listHeader.entsize=%u self.machOFile ptrSize=%lu (%d 0x%x)", listHeader.entsize, (3 * [self.machOFile ptrSize]), listHeader.entsize, [self.machOFile ptrSize], listHeader.entsize, listHeader.entsize);
        if (smallMethods) {
            NSParameterAssert(listHeader.entsize == (3 * sizeof(uint32_t)));
        } else {
            NSParameterAssert(listHeader.entsize == 3 * [self.machOFile ptrSize]);
        }
        for (uint32_t index = 0; index < listHeader.count; index++) {
            struct cd_objc2_method objc2Method;
            
            if (smallMethods) {
//                NSLog(@"NEW METHOD!!");
                uint64_t offset1 = [cursor offset];
                int value1 = [cursor readInt32];
                objc2Method.name = (uint64_t)(((int64_t)offset1) + value1);
                
                uint64_t offset2 = [cursor offset];
                int value2 = [cursor readInt32];
                objc2Method.types = (uint64_t)(((int64_t)offset2) + value2);
                
                uint64_t offset3 = [cursor offset];
                int value3 = [cursor readInt32];
                objc2Method.imp = (uint64_t)(((int64_t)offset3) + value3);
                
//                NSLog(@"values12f: 0x%016llx 0x%016llx 0x%016llx", objc2Method.name, objc2Method.types, objc2Method.imp);
//                NSLog(@"values12: 0x%08x 0x%08x 0x%08x", value1, value2, value3);
            } else {
                uint64_t value1 = [cursor readPtr];
                uint64_t value2 = [cursor readPtr];
                uint64_t value3 = [cursor readPtr];
//                NSLog(@"values24: 0x%016llx 0x%016llx 0x%016llx", value1, value2, value3);
                objc2Method.name = value1;
                objc2Method.types = value2;
                objc2Method.imp = value3;
            }
            NSString *name    = [self.machOFile stringAtAddress:objc2Method.name];
            NSString *types   = [self.machOFile stringAtAddress:objc2Method.types];
            
            if (extendedMethodTypesCursor) {
                uint64_t extendedMethodTypes = [extendedMethodTypesCursor readPtr];
                types = [self.machOFile stringAtAddress:extendedMethodTypes];
            }
            
            //NSLog(@"%3u: %016lx %016lx %016lx", index, objc2Method.name, objc2Method.types, objc2Method.imp);
            //NSLog(@"name: %@", name);
            //NSLog(@"types: %@", types);
            
            CDOCMethod *method = [[CDOCMethod alloc] initWithName:name typeString:types address:objc2Method.imp];
            [methods addObject:method];
        }
    }
    
    return [methods reversedArray];
}

- (NSArray *)loadIvarsAtAddress:(uint64_t)address;
{
    NSMutableArray *ivars = [NSMutableArray array];
    
    if (address != 0) {
        CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:address];
        NSParameterAssert([cursor offset] != 0);
        // NSLog(@"ivar list data offset: %lu", [cursor offset]);
        
        struct cd_objc2_list_header listHeader;
        
        listHeader.entsize = [cursor readInt32];
        listHeader.count = [cursor readInt32];
//        NSLog(@"Info: %u == %lu?: listHeader.entsize=%u self.machOFile ptrSize=%lu", listHeader.entsize, (3 * [self.machOFile ptrSize] + 2 * sizeof(uint32_t)), listHeader.entsize, [self.machOFile ptrSize]);
        NSParameterAssert(listHeader.entsize == 3 * [self.machOFile ptrSize] + 2 * sizeof(uint32_t));
        
        for (uint32_t index = 0; index < listHeader.count; index++) {
            struct cd_objc2_ivar objc2Ivar;
            
            objc2Ivar.offset    = [cursor readPtr];
            objc2Ivar.name      = [cursor readPtr];
            objc2Ivar.type      = [cursor readPtr];
            objc2Ivar.alignment = [cursor readInt32];
            objc2Ivar.size      = [cursor readInt32];
            
            if (objc2Ivar.name != 0) {
                NSString *name       = [self.machOFile stringAtAddress:objc2Ivar.name];
                NSString *typeString = [self.machOFile stringAtAddress:objc2Ivar.type];
                CDMachOFileDataCursor *offsetCursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:objc2Ivar.offset];
                NSUInteger offset = (uint32_t)[offsetCursor readPtr]; // objc-runtime-new.h: "offset is 64-bit by accident" => restrict to 32-bit
                
                CDOCInstanceVariable *ivar = [[CDOCInstanceVariable alloc] initWithName:name typeString:typeString offset:offset];
                [ivars addObject:ivar];
            } else {
                //NSLog(@"%016lx %016lx %016lx  %08x %08x", objc2Ivar.offset, objc2Ivar.name, objc2Ivar.type, objc2Ivar.alignment, objc2Ivar.size);
            }
        }
    }
    
    return ivars;
}

// Returns list of NSNumber containing the protocol addresses
- (NSArray *)protocolAddressListAtAddress:(uint64_t)address;
{
    NSMutableArray *addresses = [[NSMutableArray alloc] init];;
    
    if (address != 0) {
        CDMachOFileDataCursor *cursor = [[CDMachOFileDataCursor alloc] initWithFile:self.machOFile address:address];
        
        uint64_t count = [cursor readPtr];
        for (uint64_t index = 0; index < count; index++) {
            uint64_t val = [cursor readPtr];
            if (val == 0) {
                NSLog(@"Warning: protocol address in protocol list was 0.");
            } else {
                [addresses addObject:[NSNumber numberWithUnsignedLongLong:val]];
            }
        }
    }
    
    return [addresses copy];
}

- (CDSection *)objcImageInfoSection;
{
    return [[self.machOFile dataConstSegment] sectionWithName:@"__objc_imageinfo"];
}

@end
